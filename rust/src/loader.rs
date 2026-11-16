use std::collections::HashMap;
use std::rc::Rc;

use saphyr_parser::{Event, Parser, ScalarStyle, ScanError, Span, Tag};

use crate::value::{Value, resolve_plain, resolve_tagged};

/// A loaded YAML node. Sequences keep no items: they are only ever refused.
#[derive(Debug)]
pub(crate) enum Node {
    Scalar(Scalar),
    Map(Vec<(Scalar, Rc<Node>)>),
    Seq,
}

#[derive(Debug, Clone)]
pub(crate) struct Scalar {
    pub(crate) value: Value,
    pub(crate) comment: Option<String>,
}

#[derive(Debug)]
pub(crate) struct YamlError {
    pub(crate) line: usize,
    pub(crate) column: usize,
    pub(crate) message: String,
}

impl YamlError {
    fn at(span: Span, message: impl Into<String>) -> Self {
        Self {
            line: span.start.line(),
            column: span.start.col() + 1,
            message: message.into(),
        }
    }
}

impl From<ScanError> for YamlError {
    fn from(err: ScanError) -> Self {
        Self {
            line: err.marker().line(),
            column: err.marker().col() + 1,
            message: err.info().to_owned(),
        }
    }
}

type Loaded<T> = Result<T, YamlError>;

/// Loads the one document in `source`. `None` when there is none: an empty
/// file, or one with only comments.
pub(crate) fn load(source: &str) -> Loaded<Option<Rc<Node>>> {
    let mut loader = Loader {
        source,
        offsets: char_offsets(source),
        parser: Parser::new_from_str(source),
        anchors: HashMap::new(),
    };
    loader.document()
}

struct Loader<'a> {
    source: &'a str,
    offsets: Vec<usize>,
    parser: Parser<'a, saphyr_parser::StrInput<'a>>,
    anchors: HashMap<usize, Rc<Node>>,
}

impl<'a> Loader<'a> {
    fn next(&mut self) -> Loaded<(Event<'a>, Span)> {
        loop {
            match self.parser.next_event() {
                Some(Ok((Event::Nothing, _))) => continue,
                Some(Ok(event)) => return Ok(event),
                Some(Err(err)) => return Err(err.into()),
                None => {
                    return Err(YamlError {
                        line: 0,
                        column: 0,
                        message: "Unexpected end of input.".to_owned(),
                    });
                }
            }
        }
    }

    fn document(&mut self) -> Loaded<Option<Rc<Node>>> {
        let (event, span) = self.next()?;
        if !matches!(event, Event::StreamStart) {
            return Err(YamlError::at(span, "Expected the start of the stream."));
        }

        let (event, span) = self.next()?;
        match event {
            Event::StreamEnd => return Ok(None),
            Event::DocumentStart(_) => {}
            _ => return Err(YamlError::at(span, "Expected a document.")),
        }

        let (event, span) = self.next()?;
        let root = self.node(event, span)?;

        let (event, span) = self.next()?;
        if !matches!(event, Event::DocumentEnd) {
            return Err(YamlError::at(span, "Expected the end of the document."));
        }

        let (event, span) = self.next()?;
        match event {
            Event::StreamEnd => Ok(Some(root)),
            _ => Err(YamlError::at(span, "Only expected one document.")),
        }
    }

    fn node(&mut self, event: Event<'a>, span: Span) -> Loaded<Rc<Node>> {
        let (node, anchor) = match event {
            Event::Alias(id) => {
                return self
                    .anchors
                    .get(&id)
                    .cloned()
                    .ok_or_else(|| YamlError::at(span, "Undefined alias."));
            }
            Event::Scalar(text, style, anchor, tag) => (
                Node::Scalar(self.scalar(&text, style, tag.as_deref(), span)?),
                anchor,
            ),
            Event::MappingStart(anchor, tag) => {
                check_collection_tag(tag.as_deref(), "map", span)?;
                (self.mapping()?, anchor)
            }
            Event::SequenceStart(anchor, tag) => {
                check_collection_tag(tag.as_deref(), "seq", span)?;
                self.sequence()?;
                (Node::Seq, anchor)
            }
            _ => return Err(YamlError::at(span, "Expected a value.")),
        };

        let node = Rc::new(node);
        if anchor != 0 {
            self.anchors.insert(anchor, Rc::clone(&node));
        }
        Ok(node)
    }

    fn mapping(&mut self) -> Loaded<Node> {
        let mut entries: Vec<(Scalar, Rc<Node>)> = Vec::new();
        loop {
            let (event, span) = self.next()?;
            if matches!(event, Event::MappingEnd) {
                return Ok(Node::Map(entries));
            }

            let key = self.node(event, span)?;
            let Node::Scalar(key) = &*key else {
                return Err(YamlError::at(span, "A mapping key must be a scalar."));
            };
            if entries
                .iter()
                .any(|(seen, _)| seen.value.same_key(&key.value))
            {
                return Err(YamlError::at(span, "Duplicate mapping key."));
            }

            let (event, span) = self.next()?;
            let value = self.node(event, span)?;
            entries.push((key.clone(), value));
        }
    }

    fn sequence(&mut self) -> Loaded<()> {
        loop {
            let (event, span) = self.next()?;
            if matches!(event, Event::SequenceEnd) {
                return Ok(());
            }
            self.node(event, span)?;
        }
    }

    fn scalar(
        &self,
        text: &str,
        style: ScalarStyle,
        tag: Option<&Tag>,
        span: Span,
    ) -> Loaded<Scalar> {
        let tag = tag.map(|tag| format!("{}{}", tag.handle, tag.suffix));
        let value = match tag.as_deref() {
            Some("!") => Value::String(text.to_owned()),
            Some(tag) => {
                resolve_tagged(text, tag).map_err(|message| YamlError::at(span, message))?
            }
            None if style == ScalarStyle::Plain => resolve_plain(text),
            None => Value::String(text.to_owned()),
        };

        let end = match style {
            ScalarStyle::Plain => Some(self.byte(span.end.index())),
            ScalarStyle::SingleQuoted => self.quoted_end(span, '\''),
            ScalarStyle::DoubleQuoted => self.quoted_end(span, '"'),
            ScalarStyle::Literal | ScalarStyle::Folded => None,
        };

        Ok(Scalar {
            value,
            comment: end.and_then(|end| comment_after(self.source, end)),
        })
    }

    fn byte(&self, char_index: usize) -> usize {
        self.offsets
            .get(char_index)
            .copied()
            .unwrap_or(self.source.len())
    }

    /// Where a quoted scalar ends, just after its closing quote. Found here
    /// because the parser's span for a quoted scalar can run on past it.
    fn quoted_end(&self, span: Span, quote: char) -> Option<usize> {
        let start = self.byte(span.start.index());
        let open = start + self.source[start..].find(quote)?;
        let mut chars = self.source[open + 1..].char_indices();
        while let Some((i, c)) = chars.next() {
            if quote == '"' && c == '\\' {
                chars.next();
            } else if c == quote {
                if quote == '\'' && self.source[open + 1 + i + 1..].starts_with('\'') {
                    chars.next();
                } else {
                    return Some(open + 1 + i + 1);
                }
            }
        }
        None
    }
}

fn check_collection_tag(tag: Option<&Tag>, kind: &str, span: Span) -> Loaded<()> {
    let Some(tag) = tag else { return Ok(()) };
    let full = format!("{}{}", tag.handle, tag.suffix);
    if full == "!" || full == format!("tag:yaml.org,2002:{kind}") {
        return Ok(());
    }
    let what = if kind == "map" { "mapping" } else { "sequence" };
    Err(YamlError::at(span, format!("Invalid tag for {what}.")))
}

fn char_offsets(source: &str) -> Vec<usize> {
    source
        .char_indices()
        .map(|(i, _)| i)
        .chain(std::iter::once(source.len()))
        .collect()
}

/// The comment on the rest of the line after `end`: the text after the first
/// `#`, trimmed, when it is not empty.
pub(crate) fn comment_after(source: &str, end: usize) -> Option<String> {
    let rest = source.get(end..)?;
    let line = rest.split('\n').next().unwrap_or("");
    let (_, comment) = line.split_once('#')?;
    let comment = comment.trim();
    (!comment.is_empty()).then(|| comment.to_owned())
}
