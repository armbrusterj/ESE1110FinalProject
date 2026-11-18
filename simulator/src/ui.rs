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

/// Inner width of a light or fixture card.
const CARD_WIDTH: f32 = 190.0;

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

/// How a light relates to the controller's patch.
fn patch_status(sim: &Sim, l: &Light) -> (Color32, String) {
    if let Some(f) = sim.linked_fixture(l) {
        return (Color32::from_rgb(90, 200, 120), format!("patched as fixture #{}", f.id));
    }
    let end = l.address + l.ty().channel_count();
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
                    RichText::new(
                        "One card per light on the DMX line, showing what it puts out. Every patched fixture \
                         has one, whether it was added here or by a client over HTTP. Change a card's \
                         address to re-patch it.",
                    )
                    .weak(),
                );
                ui.add_space(6.0);
                let mut remove = None;
                // Lay the cards out in rows that fit the panel. (horizontal_wrapped can't
                // wrap these: it doesn't know a card's width until it has drawn it.)
                let card_w = CARD_WIDTH + 20.0 + ui.spacing().item_spacing.x + 4.0;
                let per_row = ((ui.available_width() / card_w).floor() as usize).max(1);
                let total = sim.lights.len();
                for row_start in (0..total).step_by(per_row) {
                    ui.horizontal_top(|ui| {
                        for i in row_start..(row_start + per_row).min(total) {
                            if light_card(ui, &mut sim, i) {
                                remove = Some(i);
                            }
                        }
                    });
                }
                if let Some(i) = remove {
                    remove_device(&mut sim, i);
                }
                if sim.lights.is_empty() {
                    ui.label("No lights. Add one on the right, or patch a fixture from the app.");
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
                    // Same path as POST /fixtures, so it gets the same linked light.
                    sim.add_fixture(&name, self.new_type, self.new_address);
                } else {
                    sim.lights.push(Light {
                        name: name.clone(),
                        type_idx: self.new_type,
                        address: self.new_address,
                        fixture_id: None,
                    });
                }
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
    let count = ty.channel_count();
    let values = sim.light_values(&light).to_vec();
    let (status_color, status) = patch_status(sim, &light);
    let linked = sim.linked_fixture(&light).cloned();
    let title = linked.as_ref().map_or(light.name.clone(), |f| f.name.clone());
    let mut address = light.address;

    egui::Frame::group(ui.style()).inner_margin(10.0).show(ui, |ui| {
        ui.set_width(CARD_WIDTH);
        ui.vertical(|ui| {
            ui.horizontal(|ui| {
                ui.strong(&title);
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.small_button("Remove").on_hover_text("Remove this light from the line and the patch").clicked() {
                        removed = true;
                    }
                });
            });
            ui.vertical_centered(|ui| draw_bulb(ui, light_color(ty, &values), 120.0));
            ui.horizontal(|ui| {
                ui.label(format!("{} @", ty.label));
                let max = UNIVERSE_SIZE - count + 1;
                ui.add(egui::DragValue::new(&mut address).range(1..=max))
                    .on_hover_text("Start address (drag or type)");
                if count > 1 {
                    ui.label(format!("– {}", light.address + count - 1));
                }
            });
            channel_bars(ui, ty, &values);
            ui.colored_label(status_color, RichText::new(status).small());
        });
    });

    if address != light.address {
        match linked {
            // Re-patch, exactly like PATCH /fixtures/{id} with a new address. An address
            // that would overlap another fixture is refused, as the API would refuse it.
            Some(f) => {
                if !sim.overlaps(address, count, Some(f.id)) {
                    let idx = sim.find_fixture(f.id).unwrap();
                    sim.move_fixture(idx, address);
                    sim.log(format!("UI moved \"{}\" to {address}", f.name));
                }
            }
            None => sim.lights[i].address = address,
        }
    }
    removed
}

fn channel_bars(ui: &mut egui::Ui, ty: &FixtureType, values: &[u8]) {
    for (name, v) in ty.channels.iter().zip(values) {
        ui.horizontal(|ui| {
            ui.label(RichText::new(format!("{name:>9}")).monospace());
            let bar = egui::ProgressBar::new(*v as f32 / 255.0).desired_width(78.0).fill(channel_color(name));
            ui.add(bar);
            // The value goes beside the bar, not on it, so it's readable on any fill color.
            ui.label(RichText::new(format!("{v:>3}")).monospace());
        });
    }
}

/// Removes the light at `i`, and unpatches its fixture if it has one, exactly like
/// DELETE /fixtures/{id}. Works the same whichever way the light was added.
fn remove_device(sim: &mut Sim, i: usize) {
    let light = sim.lights[i].clone();
    match sim.linked_fixture(&light).map(|f| (f.id, f.name.clone())) {
        Some((id, name)) => {
            let idx = sim.find_fixture(id).unwrap();
            sim.remove_fixture(idx); // also removes the light
            sim.log(format!("UI removed \"{name}\" (fixture #{id})"));
        }
        None => {
            sim.lights.remove(i);
            sim.log(format!("UI removed light \"{}\"", light.name));
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::route;

    fn rgb() -> usize {
        find_type("rgb").unwrap()
    }

    #[test]
    fn every_fixture_has_a_linked_light_however_it_was_added() {
        let mut sim = Sim::new(); // "Wash 1" at 1 and "Wash 2" at 4
        sim.add_fixture("Added in window", rgb(), 7); // what the Add light form does
        route(&mut sim, "POST", "/fixtures", "", r#"{"name":"Added over HTTP","type":"rgb","address":10}"#);
        assert_eq!(sim.lights.len(), 4);
        for f in &sim.fixtures {
            let lights: Vec<_> = sim.lights.iter().filter(|l| l.fixture_id == Some(f.id)).collect();
            assert_eq!(lights.len(), 1, "{} should have exactly one light", f.name);
            assert_eq!(lights[0].address, f.address);
            assert_eq!(patch_status(&sim, lights[0]).1, format!("patched as fixture #{}", f.id));
        }
    }

    #[test]
    fn http_address_change_and_delete_carry_the_light_along() {
        let mut sim = Sim::new();
        route(&mut sim, "PATCH", "/fixtures/2", "", r#"{"address":20}"#);
        assert_eq!(sim.lights[1].address, 20);
        route(&mut sim, "DELETE", "/fixtures/2", "", "");
        assert_eq!(sim.lights.len(), 1);
    }

    #[test]
    fn removing_a_card_unpatches_its_fixture() {
        let mut sim = Sim::new();
        route(&mut sim, "POST", "/fixtures", "", r#"{"name":"Spot","type":"rgb","address":7}"#);
        sim.universe[6] = 200;
        remove_device(&mut sim, 2); // the Spot card
        remove_device(&mut sim, 0); // the Wash 1 card
        assert_eq!(sim.fixtures.iter().map(|f| f.name.as_str()).collect::<Vec<_>>(), ["Wash 2"]);
        assert_eq!(sim.lights.len(), 1);
        assert_eq!(sim.universe[6], 0, "its channels are cleared, like DELETE /fixtures/{{id}}");
    }

    #[test]
    fn unpatched_lights_stay_out_of_the_patch() {
        let mut sim = Sim::new();
        sim.lights.push(Light { name: "Extra".into(), type_idx: rgb(), address: 100, fixture_id: None });
        assert_eq!(patch_status(&sim, &sim.lights[2]).1, "not patched");
        remove_device(&mut sim, 2);
        assert_eq!((sim.lights.len(), sim.fixtures.len()), (2, 2));
    }

    #[test]
    fn patching_where_an_unpatched_light_sits_adopts_it() {
        let mut sim = Sim::new();
        sim.lights.push(Light { name: "Extra".into(), type_idx: rgb(), address: 100, fixture_id: None });
        route(&mut sim, "POST", "/fixtures", "", r#"{"name":"Spot","type":"rgb","address":100}"#);
        assert_eq!(sim.lights.len(), 3);
        assert!(sim.lights[2].fixture_id.is_some());
    }
}
