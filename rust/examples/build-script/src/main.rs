//! Values from `app.demo.yaml`, decrypted at build time by `build.rs`.

const APP_NAME: &str = env!("APP_NAME");
const DATABASE_URL: &str = env!("DATABASE_URL");
const API_KEY: &str = env!("API_KEY");

fn main() {
    let port: u16 = env!("SERVER_PORT").parse().expect("SERVER_PORT is a port");

    println!("{APP_NAME} listens on port {port}");
    println!("database: {DATABASE_URL}");
    println!("api key: {}…", &API_KEY[..7]);
}
