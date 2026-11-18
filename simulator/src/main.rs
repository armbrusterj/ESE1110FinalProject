//! DMXtra simulator: runs the controller's HTTP API on your computer and shows
//! the simulated lights in an egui window.
//!
//!     cargo run --release -- --host 0.0.0.0 --port 8080 --latency 30

mod api;
mod state;
mod ui;

use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Args {
    host: String,
    port: u16,
    latency_ms: u64,
}

fn parse_args() -> Args {
    let mut args = Args { host: "127.0.0.1".into(), port: 8080, latency_ms: 0 };
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        let mut val = |name: &str| it.next().unwrap_or_else(|| die(&format!("{name} needs a value")));
        match a.as_str() {
            "--host" => args.host = val("--host"),
            "--port" => args.port = val("--port").parse().unwrap_or_else(|_| die("--port must be a number")),
            "--latency" => {
                args.latency_ms = val("--latency").parse().unwrap_or_else(|_| die("--latency must be milliseconds"))
            }
            "-h" | "--help" => {
                println!(
                    "Usage: dmxtra-simulator [--host 127.0.0.1] [--port 8080] [--latency MS]\n\n\
                     --host     interface to bind (0.0.0.0 to reach it from a phone on the same WiFi)\n\
                     --port     TCP port (default 8080)\n\
                     --latency  extra delay per request in ms, to feel more like the board"
                );
                std::process::exit(0);
            }
            other => die(&format!("unknown argument {other} (try --help)")),
        }
    }
    args
}

fn die(msg: &str) -> ! {
    eprintln!("error: {msg}");
    std::process::exit(2);
}

fn main() -> eframe::Result {
    let args = parse_args();
    let addr = format!("{}:{}", args.host, args.port);
    let server = tiny_http::Server::http(&addr).unwrap_or_else(|e| die(&format!("can't listen on {addr}: {e}")));
    println!("DMXtra simulator listening on http://{addr}");

    let sim = Arc::new(Mutex::new(state::Sim::new()));
    let latency = Duration::from_millis(args.latency_ms);

    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("DMXtra Simulator")
            .with_inner_size([1100.0, 720.0]),
        ..Default::default()
    };

    eframe::run_native(
        "DMXtra Simulator",
        options,
        Box::new(move |cc| {
            let ctx = cc.egui_ctx.clone();
            let server_sim = sim.clone();
            std::thread::spawn(move || api::serve(server, server_sim, latency, move || ctx.request_repaint()));
            Ok(Box::new(ui::SimApp::new(sim, addr)))
        }),
    )
}
