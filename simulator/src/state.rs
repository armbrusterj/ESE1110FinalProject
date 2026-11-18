//! Simulated controller state. Mirrors the data model in embedded/src/main.cpp:
//! the universe is the single source of truth, fixtures (the patch) are named
//! views onto it, and lights (receivers) read their channels from it.

use std::collections::VecDeque;
use std::time::SystemTime;

pub const FIRMWARE_VERSION: &str = "0.2.0";
pub const UNIVERSE_SIZE: usize = 512;
pub const MAX_FIXTURES: usize = 32;
pub const MAX_NAME_LEN: usize = 31;
const MAX_LOG: usize = 200;

pub struct FixtureType {
    pub key: &'static str,
    pub label: &'static str,
    pub channels: &'static [&'static str],
}

impl FixtureType {
    pub fn channel_count(&self) -> usize {
        self.channels.len()
    }
}

pub const FIXTURE_TYPES: &[FixtureType] = &[
    FixtureType { key: "dimmer", label: "Dimmer", channels: &["intensity"] },
    FixtureType { key: "rgb", label: "RGB", channels: &["red", "green", "blue"] },
    FixtureType { key: "rgbw", label: "RGBW", channels: &["red", "green", "blue", "white"] },
];

pub fn find_type(key: &str) -> Option<usize> {
    FIXTURE_TYPES.iter().position(|t| t.key == key)
}

/// A patched fixture: what the controller knows about (the HTTP API's "fixture").
#[derive(Clone)]
pub struct Fixture {
    pub id: u16,
    pub name: String,
    pub type_idx: usize,
    pub address: usize, // 1-based
}

impl Fixture {
    pub fn ty(&self) -> &'static FixtureType {
        &FIXTURE_TYPES[self.type_idx]
    }
}

/// A simulated light on the DMX line. It reads its channels from the universe at
/// its start address, like the RgbReceiver test LEDs.
///
/// Every patched fixture has exactly one light linked to it, however the fixture was
/// created (at boot, from the window, or over HTTP): the light follows the fixture's
/// address and goes away with it. A light can also be unlinked (added in the window
/// without patching it), in which case it keeps its own fixed address.
#[derive(Clone)]
pub struct Light {
    pub name: String,
    pub type_idx: usize,
    pub address: usize, // 1-based
    pub fixture_id: Option<u16>,
}

impl Light {
    pub fn ty(&self) -> &'static FixtureType {
        &FIXTURE_TYPES[self.type_idx]
    }
}

pub struct LogEntry {
    pub time: SystemTime,
    pub line: String,
}

pub struct Sim {
    pub universe: [u8; UNIVERSE_SIZE], // index 0 == DMX channel 1
    pub fixtures: Vec<Fixture>,
    pub next_fixture_id: u16,
    pub lights: Vec<Light>,
    pub log: VecDeque<LogEntry>,
}

impl Sim {
    /// Same state the board boots into.
    pub fn new() -> Self {
        let mut sim = Sim {
            universe: [0; UNIVERSE_SIZE],
            fixtures: Vec::new(),
            next_fixture_id: 1,
            lights: Vec::new(),
            log: VecDeque::new(),
        };
        // The default patch. Their lights stand in for the two test LEDs wired to the
        // board, on channels 1-3 and 4-6.
        let rgb = find_type("rgb").unwrap();
        sim.add_fixture("Wash 1", rgb, 1);
        sim.add_fixture("Wash 2", rgb, 4);
        sim
    }

    pub fn log(&mut self, line: impl Into<String>) {
        if self.log.len() >= MAX_LOG {
            self.log.pop_front();
        }
        self.log.push_back(LogEntry { time: SystemTime::now(), line: line.into() });
    }

    pub fn find_fixture(&self, id: u16) -> Option<usize> {
        self.fixtures.iter().position(|f| f.id == id)
    }

    /// True if [address, address+count) collides with any fixture other than `ignore_id`.
    pub fn overlaps(&self, address: usize, count: usize, ignore_id: Option<u16>) -> bool {
        let end = address + count;
        self.fixtures.iter().any(|f| {
            Some(f.id) != ignore_id && address < f.address + f.ty().channel_count() && f.address < end
        })
    }

    /// Patches a fixture and gives it a light: an unlinked light of the same type
    /// already at that address if there is one, otherwise a new one.
    pub fn add_fixture(&mut self, name: &str, type_idx: usize, address: usize) -> Option<usize> {
        if self.fixtures.len() >= MAX_FIXTURES {
            return None;
        }
        let id = self.next_fixture_id;
        self.fixtures.push(Fixture { id, name: name.to_string(), type_idx, address });
        self.next_fixture_id = self.next_fixture_id.wrapping_add(1);
        match self
            .lights
            .iter_mut()
            .find(|l| l.fixture_id.is_none() && l.address == address && l.type_idx == type_idx)
        {
            Some(l) => l.fixture_id = Some(id),
            None => self.lights.push(Light { name: name.to_string(), type_idx, address, fixture_id: Some(id) }),
        }
        Some(self.fixtures.len() - 1)
    }

    /// Unpatches a fixture, clears its channels, and removes its light.
    pub fn remove_fixture(&mut self, idx: usize) {
        let f = self.fixtures.remove(idx);
        for i in 0..f.ty().channel_count() {
            self.universe[f.address - 1 + i] = 0;
        }
        self.lights.retain(|l| l.fixture_id != Some(f.id));
    }

    /// Moves a fixture (the caller has checked the address fits and doesn't overlap).
    /// Its current look moves with it, its old channels go dark, and its light follows.
    pub fn move_fixture(&mut self, idx: usize, address: usize) {
        let f = self.fixtures[idx].clone();
        if address == f.address {
            return;
        }
        let count = f.ty().channel_count();
        let current: Vec<u8> = self.fixture_values(&f).to_vec();
        for i in 0..count {
            self.universe[f.address - 1 + i] = 0;
        }
        self.universe[address - 1..address - 1 + count].copy_from_slice(&current);
        self.fixtures[idx].address = address;
        for l in self.lights.iter_mut().filter(|l| l.fixture_id == Some(f.id)) {
            l.address = address;
        }
    }

    /// The fixture a light is linked to, if any.
    pub fn linked_fixture(&self, l: &Light) -> Option<&Fixture> {
        l.fixture_id.and_then(|id| self.find_fixture(id)).map(|i| &self.fixtures[i])
    }

    pub fn fixture_values(&self, f: &Fixture) -> &[u8] {
        &self.universe[f.address - 1..f.address - 1 + f.ty().channel_count()]
    }

    pub fn light_values(&self, l: &Light) -> &[u8] {
        let start = l.address - 1;
        let end = (start + l.ty().channel_count()).min(UNIVERSE_SIZE);
        &self.universe[start..end]
    }

    /// Fixtures sorted by address (then id), like GET /fixtures.
    pub fn sorted_fixtures(&self) -> Vec<&Fixture> {
        let mut v: Vec<&Fixture> = self.fixtures.iter().collect();
        v.sort_by_key(|f| (f.address, f.id));
        v
    }
}

pub fn address_fits(address: i64, count: usize) -> bool {
    address >= 1 && address + count as i64 - 1 <= UNIVERSE_SIZE as i64
}
