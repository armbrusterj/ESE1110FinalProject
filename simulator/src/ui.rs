//! egui window: one card per simulated light showing its output, a form to add
//! lights, the controller's patch, the raw universe, and a request log.

use std::sync::{Arc, Mutex};
use std::time::UNIX_EPOCH;

use eframe::egui::{self, Color32, RichText, Sense, Stroke, Vec2};

use crate::state::*;

pub struct SimApp {
    sim: Arc<Mutex<Sim>>,
    addr: String,
    new_name: String,
    new_type: usize,
    new_address: usize,
    also_patch: bool,
    message: Option<(bool, String)>, // (is_error, text)
}

impl SimApp {
    pub fn new(sim: Arc<Mutex<Sim>>, addr: String) -> Self {
        SimApp {
            sim,
            addr,
            new_name: "Light 3".into(),
            new_type: find_type("rgb").unwrap(),
            new_address: 7,
            also_patch: true,
            message: None,
        }
    }
}

/// The colour a light would actually emit for its channel values.
fn light_color(ty: &FixtureType, v: &[u8]) -> Color32 {
    let ch = |i: usize| v.get(i).copied().unwrap_or(0) as f32;
    let (r, g, b) = match ty.key {
        "dimmer" => {
            let k = ch(0) / 255.0;
            (255.0 * k, 214.0 * k, 170.0 * k) // warm white
        }
        "rgbw" => (ch(0) + ch(3), ch(1) + ch(3) * 0.95, ch(2) + ch(3) * 0.85),
        _ => (ch(0), ch(1), ch(2)),
    };
    Color32::from_rgb(r.min(255.0) as u8, g.min(255.0) as u8, b.min(255.0) as u8)
}

fn channel_color(name: &str) -> Color32 {
    match name {
        "red" => Color32::from_rgb(230, 70, 70),
        "green" => Color32::from_rgb(70, 200, 90),
        "blue" => Color32::from_rgb(80, 130, 255),
        _ => Color32::from_rgb(230, 220, 200),
    }
}

fn draw_bulb(ui: &mut egui::Ui, color: Color32, size: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(size), Sense::hover());
    let p = ui.painter();
    let c = rect.center();
    let r = size * 0.3;
    let brightness = color.r().max(color.g()).max(color.b()) as f32 / 255.0;
    // Glow, stronger the brighter the light.
    for i in (1..=6).rev() {
        let t = i as f32 / 6.0;
        let alpha = (brightness * 60.0 * (1.0 - t)) as u8;
        p.circle_filled(c, r + t * size * 0.2, Color32::from_rgba_unmultiplied(color.r(), color.g(), color.b(), alpha));
    }
    let lens = if brightness < 0.02 { Color32::from_gray(40) } else { color };
    p.circle_filled(c, r, lens);
    p.circle_stroke(c, r, Stroke::new(2.0, Color32::from_gray(90)));
}

/// How the light at this address relates to the controller's patch.
fn patch_status(sim: &Sim, l: &Light) -> (Color32, String) {
    let count = l.ty().channel_count();
    if let Some(f) = sim.fixtures.iter().find(|f| f.address == l.address && f.type_idx == l.type_idx) {
        return (Color32::from_rgb(90, 200, 120), format!("patched as \"{}\" (#{})", f.name, f.id));
    }
    let end = l.address + count;
    if let Some(f) = sim.fixtures.iter().find(|f| l.address < f.address + f.ty().channel_count() && f.address < end) {
        return (Color32::from_rgb(230, 170, 60), format!("overlaps \"{}\" (#{})", f.name, f.id));
    }
    (Color32::GRAY, "not patched".into())
}

impl eframe::App for SimApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let sim_arc = self.sim.clone();
        let mut sim = sim_arc.lock().unwrap();

        egui::Panel::top("top").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading("DMXtra Simulator");
                ui.separator();
                ui.label(format!("API on http://{}", self.addr));
                ui.separator();
                ui.label(format!("firmware {FIRMWARE_VERSION}"));
                ui.label(format!("{} / {MAX_FIXTURES} fixtures patched", sim.fixtures.len()));
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.button("Blackout").clicked() {
                        sim.universe = [0; UNIVERSE_SIZE];
                        sim.log("UI blackout");
                    }
                });
            });
        });

        egui::Panel::right("side").min_size(300.0).show(ui, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                self.add_light_form(ui, &mut sim);
                ui.separator();
                patch_list(ui, &sim);
                ui.separator();
                request_log(ui, &sim);
            });
        });

        egui::CentralPanel::default_margins().show(ui, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.heading("Lights");
                ui.label(
                    RichText::new("Each light listens on a fixed start address, like DIP switches on real hardware.")
                        .weak(),
                );
                ui.add_space(6.0);
                let mut remove = None;
                ui.horizontal_wrapped(|ui| {
                    for i in 0..sim.lights.len() {
                        if light_card(ui, &mut sim, i) {
                            remove = Some(i);
                        }
                    }
                });
                if let Some(i) = remove {
                    let l = sim.lights.remove(i);
                    sim.log(format!("UI removed light \"{}\"", l.name));
                }
                if sim.lights.is_empty() {
                    ui.label("No lights. Add one on the right.");
                }
                ui.add_space(12.0);
                egui::CollapsingHeader::new("Universe (channels 1-512)").default_open(true).show(ui, |ui| {
                    universe_grid(ui, &sim);
                });
            });
        });
    }
}

impl SimApp {
    fn add_light_form(&mut self, ui: &mut egui::Ui, sim: &mut Sim) {
        ui.heading("Add light");
        let ty = &FIXTURE_TYPES[self.new_type];
        let max_addr = UNIVERSE_SIZE - ty.channel_count() + 1;
        egui::Grid::new("add").num_columns(2).show(ui, |ui| {
            ui.label("Name");
            ui.add(egui::TextEdit::singleline(&mut self.new_name).char_limit(MAX_NAME_LEN));
            ui.end_row();
            ui.label("Type");
            egui::ComboBox::from_id_salt("type")
                .selected_text(format!("{} ({} ch)", ty.label, ty.channel_count()))
                .show_ui(ui, |ui| {
                    for (i, t) in FIXTURE_TYPES.iter().enumerate() {
                        ui.selectable_value(&mut self.new_type, i, format!("{} ({} ch)", t.label, t.channel_count()));
                    }
                });
            ui.end_row();
            ui.label("Address");
            ui.add(egui::DragValue::new(&mut self.new_address).range(1..=max_addr));
            ui.end_row();
        });
        self.new_address = self.new_address.clamp(1, max_addr);
        ui.checkbox(&mut self.also_patch, "Also patch it on the controller");

        if ui.button("Add light").clicked() {
            let name = self.new_name.trim().to_string();
            let count = ty.channel_count();
            if name.is_empty() {
                self.message = Some((true, "Give the light a name.".into()));
            } else if self.also_patch && sim.overlaps(self.new_address, count, None) {
                self.message = Some((true, "Can't patch: address overlaps another fixture.".into()));
            } else if self.also_patch && sim.fixtures.len() >= MAX_FIXTURES {
                self.message = Some((true, "Can't patch: patch is full.".into()));
            } else {
                if self.also_patch {
                    sim.add_fixture(&name, self.new_type, self.new_address);
                }
                sim.lights.push(Light { name: name.clone(), type_idx: self.new_type, address: self.new_address });
                sim.log(format!("UI added light \"{name}\" at {}", self.new_address));
                self.message = Some((false, format!("Added \"{name}\".")));
                // Get the form ready for the next one.
                self.new_address = (self.new_address + count).min(max_addr);
                self.new_name = format!("Light {}", sim.lights.len() + 1);
            }
        }
        if let Some((is_err, msg)) = &self.message {
            let color = if *is_err { Color32::from_rgb(230, 90, 90) } else { Color32::from_rgb(90, 200, 120) };
            ui.colored_label(color, msg);
        }
    }
}

/// Draws one light. Returns true if its remove button was clicked.
fn light_card(ui: &mut egui::Ui, sim: &mut Sim, i: usize) -> bool {
    let mut removed = false;
    let light = sim.lights[i].clone();
    let ty = light.ty();
    let values = sim.light_values(&light).to_vec();
    let (status_color, status) = patch_status(sim, &light);

    egui::Frame::group(ui.style()).inner_margin(10.0).show(ui, |ui| {
        ui.set_width(190.0);
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.strong(&light.name);
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.small_button("Remove").on_hover_text("Remove light").clicked() {
                        removed = true;
                    }
                });
            });
            ui.vertical_centered(|ui| draw_bulb(ui, light_color(ty, &values), 120.0));
            let end = light.address + ty.channel_count() - 1;
            ui.horizontal(|ui| {
                ui.label(format!("{} @", ty.label));
                let max = UNIVERSE_SIZE - ty.channel_count() + 1;
                ui.add(egui::DragValue::new(&mut sim.lights[i].address).range(1..=max))
                    .on_hover_text("Start address (drag or type)");
                ui.label(format!("– {end}"));
            });
            for (name, v) in ty.channels.iter().zip(&values) {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(format!("{name:>9}")).monospace());
                    let bar = egui::ProgressBar::new(*v as f32 / 255.0)
                        .desired_width(90.0)
                        .fill(channel_color(name))
                        .text(RichText::new(v.to_string()).monospace());
                    ui.add(bar);
                });
            }
            ui.colored_label(status_color, RichText::new(status).small());
        });
    });
    removed
}

fn patch_list(ui: &mut egui::Ui, sim: &Sim) {
    ui.heading("Controller patch");
    ui.label(RichText::new("What the API reports from GET /fixtures.").weak());
    if sim.fixtures.is_empty() {
        ui.label("Nothing patched.");
        return;
    }
    egui::Grid::new("patch").num_columns(4).striped(true).show(ui, |ui| {
        ui.strong("#");
        ui.strong("Name");
        ui.strong("Type");
        ui.strong("Channels");
        ui.end_row();
        for f in sim.sorted_fixtures() {
            let end = f.address + f.ty().channel_count() - 1;
            ui.label(f.id.to_string());
            ui.label(&f.name);
            ui.label(f.ty().label);
            ui.label(if end == f.address { f.address.to_string() } else { format!("{}–{end}", f.address) });
            ui.end_row();
        }
    });
}

fn request_log(ui: &mut egui::Ui, sim: &Sim) {
    ui.heading("Requests");
    if sim.log.is_empty() {
        ui.label(RichText::new("No requests yet.").weak());
    }
    for e in sim.log.iter().rev().take(60) {
        let secs = e.time.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let (h, m, s) = ((secs / 3600) % 24, (secs / 60) % 60, secs % 60);
        ui.label(RichText::new(format!("{h:02}:{m:02}:{s:02} UTC  {}", e.line)).monospace().small());
    }
}

/// 512 cells, 32 per row; each cell's brightness is its channel value.
fn universe_grid(ui: &mut egui::Ui, sim: &Sim) {
    const COLS: usize = 32;
    let cell = ((ui.available_width() - 40.0) / COLS as f32).clamp(10.0, 26.0);
    let rows = UNIVERSE_SIZE / COLS;
    let (rect, resp) =
        ui.allocate_exact_size(Vec2::new(40.0 + cell * COLS as f32, cell * rows as f32), Sense::hover());
    let p = ui.painter_at(rect);
    let patched = |ch: usize| sim.fixtures.iter().any(|f| ch >= f.address && ch < f.address + f.ty().channel_count());
    for row in 0..rows {
        let y = rect.top() + row as f32 * cell;
        p.text(
            egui::pos2(rect.left() + 34.0, y + cell / 2.0),
            egui::Align2::RIGHT_CENTER,
            (row * COLS + 1).to_string(),
            egui::FontId::monospace(9.0),
            ui.visuals().weak_text_color(),
        );
        for col in 0..COLS {
            let ch = row * COLS + col + 1;
            let v = sim.universe[ch - 1];
            let r = egui::Rect::from_min_size(egui::pos2(rect.left() + 40.0 + col as f32 * cell, y), Vec2::splat(cell))
                .shrink(1.0);
            let g = 30 + (v as u32 * 225 / 255) as u8;
            p.rect_filled(r, 2.0, Color32::from_rgb(g, g, (g as u32 * 9 / 10) as u8));
            if patched(ch) {
                p.rect_stroke(r, 2.0, Stroke::new(1.0, Color32::from_rgb(90, 140, 220)), egui::StrokeKind::Inside);
            }
        }
    }
    if let Some(pos) = resp.hover_pos() {
        let col = ((pos.x - rect.left() - 40.0) / cell).floor();
        let row = ((pos.y - rect.top()) / cell).floor();
        if col >= 0.0 && (col as usize) < COLS && row >= 0.0 && (row as usize) < rows {
            let ch = row as usize * COLS + col as usize + 1;
            resp.on_hover_text(format!("Channel {ch}: {}", sim.universe[ch - 1]));
        }
    }
}
