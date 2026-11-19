//! A small reader for the YAML a secrets file holds: nested mappings of
//! scalars, with the comment that trails each scalar.

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;
use saphyr_parser::{Event, Parser, ScalarStyle, Span};

/// A scalar value at the end of a path of mapping keys.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Leaf {
    /// The keys from the top of the file.
    pub path: Vec<String>,
    /// The scalar's text.
    pub text: String,
    /// Whether YAML's core schema reads it as a string (not a number, bool or
    /// null).
    pub is_string: bool,
    /// The trimmed text after a `#` on the value's own line, if any.
    pub comment: Option<String>,
}

#[derive(Clone)]
enum Node {
    Scalar {
        text: String,
        is_string: bool,
        /// Where the value ends, in characters from the start of the file.
        end: usize,
    },
    Map(Vec<(String, Node)>),
    Seq,
}

/// The leaves of every document's top-level mapping, in file order.
///
/// A file may hold several documents separated by `---`; each is read.
/// Sequences are skipped whole. A document that is empty or whose top level
/// is not a mapping has no leaves.
pub(crate) fn leaves(source: &str) -> Result<Vec<Leaf>, String> {
    let mut parser = Parser::new_from_str(source);
    let mut anchors = HashMap::new();
    let mut roots = Vec::new();

    while let Some(next) = parser.next_event() {
        let (event, span) = next.map_err(|err| err.to_string())?;
        match event {
            Event::StreamEnd => break,
            // Anchors do not reach across documents.
            Event::DocumentStart(_) => anchors.clear(),
            Event::StreamStart | Event::DocumentEnd => {}
            first => roots.push(build(first, span, &mut parser, &mut anchors)?),
        }
    }

    let chars: Vec<char> = source.chars().collect();
    let mut out = Vec::new();
    for root in &roots {
        if let Node::Map(entries) = root {
            collect(entries, &mut Vec::new(), &chars, &mut out);
        }
    }
    Ok(out)
}

type Events<'a> = Parser<'a, saphyr_parser::StrInput<'a>>;

fn build(
    event: Event<'_>,
    span: Span,
    parser: &mut Events<'_>,
    anchors: &mut HashMap<usize, Node>,
) -> Result<Node, String> {
    let (node, anchor) = match event {
        Event::Scalar(text, style, anchor, tag) => {
            let is_string = match tag.as_deref() {
                Some(tag) => tag.suffix == "str",
                None => style != ScalarStyle::Plain || resolves_to_string(&text),
            };
            (
                Node::Scalar {
                    text: text.into_owned(),
                    is_string,
                    end: span.end.index(),
                },
                anchor,
            )
        }
        Event::Alias(id) => {
            return Ok(anchors.get(&id).cloned().unwrap_or(Node::Seq));
        }
        Event::SequenceStart(anchor, _) => {
            skip_collection(parser, anchors)?;
            (Node::Seq, anchor)
        }
        Event::MappingStart(anchor, _) => {
            let mut entries = Vec::new();
            loop {
                let (event, span) = next(parser)?;
                if matches!(event, Event::MappingEnd) {
                    break;
                }
                let key = match build(event, span, parser, anchors)? {
                    Node::Scalar { text, .. } => text,
                    _ => String::new(),
                };
                let (event, span) = next(parser)?;
                let value = build(event, span, parser, anchors)?;
                entries.push((key, value));
            }
            (Node::Map(entries), anchor)
        }
        _ => return Err("unexpected YAML structure".to_owned()),
    };

    if anchor != 0 {
        anchors.insert(anchor, node.clone());
    }
    Ok(node)
}

fn next<'a>(parser: &mut Events<'a>) -> Result<(Event<'a>, Span), String> {
    match parser.next_event() {
        Some(Ok(pair)) => Ok(pair),
        Some(Err(err)) => Err(err.to_string()),
        None => Err("unexpected end of YAML".to_owned()),
    }
}

fn skip_collection(
    parser: &mut Events<'_>,
    anchors: &mut HashMap<usize, Node>,
) -> Result<(), String> {
    loop {
        let (event, span) = next(parser)?;
        match event {
            Event::SequenceEnd => return Ok(()),
            other => {
                build(other, span, parser, anchors)?;
            }
        }
    }
}

fn collect(
    entries: &[(String, Node)],
    path: &mut Vec<String>,
    chars: &[char],
    out: &mut Vec<Leaf>,
) {
    for (key, node) in entries {
        path.push(key.clone());
        match node {
            Node::Scalar {
                text,
                is_string,
                end,
            } => out.push(Leaf {
                path: path.clone(),
                text: text.clone(),
                is_string: *is_string,
                comment: comment_after(chars, *end),
            }),
            Node::Map(inner) => collect(inner, path, chars, out),
            Node::Seq => {}
        }
        path.pop();
    }
}

/// The comment on the rest of the line the value ends on.
fn comment_after(chars: &[char], end: usize) -> Option<String> {
    let rest = chars.get(end..)?;
    let line_end = rest.iter().position(|c| *c == '\n').unwrap_or(rest.len());
    let line = &rest[..line_end];
    let hash = line.iter().position(|c| *c == '#')?;
    let comment: String = line[hash + 1..].iter().collect();
    let comment = comment.trim();
    (!comment.is_empty()).then(|| comment.to_owned())
}

static NON_STRING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^(?:~|null|Null|NULL|true|True|TRUE|false|False|FALSE|[-+]?[0-9]+|0x[0-9a-fA-F]+|0o[0-7]+|[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$",
    )
    .expect("a valid pattern")
});

/// Whether a plain scalar is a string under the YAML 1.2 core schema.
fn resolves_to_string(text: &str) -> bool {
    !text.is_empty() && !NON_STRING.is_match(text)
}
