//! The Rust connection scan engine of the routing experiment,
//! compiled to WebAssembly. It reads the routing snapshot files of format
//! version 1, as `Gobusgo.Routing.SnapshotFormat` writes them, and answers a
//! query with its Pareto frontier over arrival time and changes.
//!
//! The rules are those of `../engine/csa.js`, comparison for comparison, so
//! the two engines return the same frontiers: rounds that each add one ride,
//! boarding only where the round before could board in time, the minimum
//! transfer after a ride, one walking link after the origin and after each
//! ride, and a round's journey kept only when it arrives strictly earlier.
//!
//! The exports work on the module's linear memory: a caller copies a file in
//! through `alloc`, hands it over with `add_*`, and reads a result back from
//! `result_ptr` and `result_len` as `i32` values.

use std::cell::RefCell;

pub const ROUNDS_MAX: usize = 6;
const LEG_COUNT_MAX: usize = 2 * ROUNDS_MAX + 1;
const UNREACHED: i32 = i32::MAX;
const PARENT_NONE: u8 = 0;
const PARENT_RIDE: u8 = 1;
const PARENT_WALK_AFTER_RIDE: u8 = 2;
const PARENT_WALK_FROM_ORIGIN: u8 = 3;

const MAGIC: &[u8; 4] = b"GBRT";
const FORMAT_VERSION: u16 = 1;
const HEADER_BYTES: usize = 16;
const KIND_STOPS: u16 = 1;
const KIND_TRANSFERS: u16 = 3;
const KIND_CONNECTIONS: u16 = 4;
const TRANSFER_BYTES: usize = 12;
const CONNECTION_BYTES: usize = 24;
const BOARDING_BIT: u8 = 1;
const ALIGHTING_BIT: u8 = 2;

/// Why a file was refused.
#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    InvalidHeader = 1,
    UnsupportedVersion = 2,
    InvalidLength = 3,
    OutOfOrder = 4,
}

#[derive(Default)]
pub struct Connections {
    pub departure_s: Vec<i32>,
    pub arrival_s: Vec<i32>,
    pub departure_stop: Vec<u32>,
    pub arrival_stop: Vec<u32>,
    pub trip: Vec<u32>,
    pub boarding: Vec<bool>,
    pub alighting: Vec<bool>,
}

#[derive(Default)]
pub struct Engine {
    pub stop_count: usize,
    pub connections: Connections,
    link_from: Vec<u32>,
    link_to: Vec<u32>,
    link_duration_s: Vec<i32>,
    link_offsets: Vec<usize>,
    trip_count: usize,
    pub minimum_transfer_s: i32,
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum Leg {
    Ride { board_connection: u32, alight_connection: u32 },
    Walk { from_stop: u32, to_stop: u32, duration_s: i32 },
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub struct Journey {
    pub arrival_s: i32,
    pub changes: u32,
    pub legs: Vec<Leg>,
}

fn header(file: &[u8], kind: u16) -> Result<usize, Refusal> {
    if file.len() < HEADER_BYTES || &file[0..4] != MAGIC {
        return Err(Refusal::InvalidHeader);
    }

    if u16::from_le_bytes([file[4], file[5]]) != FORMAT_VERSION {
        return Err(Refusal::UnsupportedVersion);
    }

    if u16::from_le_bytes([file[6], file[7]]) != kind {
        return Err(Refusal::InvalidHeader);
    }

    Ok(u32::from_le_bytes([file[8], file[9], file[10], file[11]]) as usize)
}

fn u32_at(file: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([file[offset], file[offset + 1], file[offset + 2], file[offset + 3]])
}

fn i32_at(file: &[u8], offset: usize) -> i32 {
    i32::from_le_bytes([file[offset], file[offset + 1], file[offset + 2], file[offset + 3]])
}

impl Engine {
    /// Reads the stop count from a stops file.
    pub fn set_stops(&mut self, file: &[u8]) -> Result<(), Refusal> {
        self.stop_count = header(file, KIND_STOPS)?;
        Ok(())
    }

    /// Appends the connections of one chunk, which must depart no earlier
    /// than the connections already held.
    pub fn add_connections(&mut self, file: &[u8]) -> Result<(), Refusal> {
        let count = header(file, KIND_CONNECTIONS)?;

        if file.len() != HEADER_BYTES + count * CONNECTION_BYTES {
            return Err(Refusal::InvalidLength);
        }

        let connections = &mut self.connections;

        for index in 0..count {
            let offset = HEADER_BYTES + index * CONNECTION_BYTES;
            let departure_s = i32_at(file, offset);
            let is_ordered = connections.departure_s.last().map_or(true, |last| *last <= departure_s);

            if !is_ordered {
                return Err(Refusal::OutOfOrder);
            }

            let trip = u32_at(file, offset + 16);
            let flags = file[offset + 22];
            connections.departure_s.push(departure_s);
            connections.arrival_s.push(i32_at(file, offset + 4));
            connections.departure_stop.push(u32_at(file, offset + 8));
            connections.arrival_stop.push(u32_at(file, offset + 12));
            connections.trip.push(trip);
            connections.boarding.push(flags & BOARDING_BIT != 0);
            connections.alighting.push(flags & ALIGHTING_BIT != 0);
            self.trip_count = self.trip_count.max(trip as usize + 1);
        }

        Ok(())
    }

    /// Reads the walking links of a transfers file, ordered by the stop they leave.
    pub fn set_transfers(&mut self, file: &[u8]) -> Result<(), Refusal> {
        let count = header(file, KIND_TRANSFERS)?;

        if file.len() != HEADER_BYTES + count * TRANSFER_BYTES {
            return Err(Refusal::InvalidLength);
        }

        self.link_from.clear();
        self.link_to.clear();
        self.link_duration_s.clear();

        for index in 0..count {
            let offset = HEADER_BYTES + index * TRANSFER_BYTES;
            self.link_from.push(u32_at(file, offset));
            self.link_to.push(u32_at(file, offset + 4));
            self.link_duration_s.push(u32_at(file, offset + 8) as i32);
        }

        Ok(())
    }

    /// Builds the walking link offsets once the stops and transfers are set.
    pub fn finish(&mut self) {
        let mut offsets = vec![0usize; self.stop_count + 1];

        for from in &self.link_from {
            offsets[*from as usize + 1] += 1;
        }

        for stop in 0..self.stop_count {
            offsets[stop + 1] += offsets[stop];
        }

        self.link_offsets = offsets;
    }

    fn first_connection(&self, departure_s: i32) -> usize {
        self.connections.departure_s.partition_point(|time| *time < departure_s)
    }
}

#[derive(Clone)]
struct Label {
    time_s: Vec<i32>,
    kind: Vec<u8>,
    a: Vec<i32>,
    b: Vec<i32>,
    c: Vec<i32>,
    round: Vec<u8>,
}

impl Label {
    fn new(stop_count: usize) -> Label {
        Label {
            time_s: vec![UNREACHED; stop_count],
            kind: vec![PARENT_NONE; stop_count],
            a: vec![0; stop_count],
            b: vec![0; stop_count],
            c: vec![0; stop_count],
            round: vec![0; stop_count],
        }
    }

    fn improve(&mut self, stop: usize, time_s: i32, parent: (u8, i32, i32, i32, u8)) {
        if time_s < self.time_s[stop] {
            self.time_s[stop] = time_s;
            self.kind[stop] = parent.0;
            self.a[stop] = parent.1;
            self.b[stop] = parent.2;
            self.c[stop] = parent.3;
            self.round[stop] = parent.4;
        }
    }
}

#[derive(Clone)]
struct State {
    arrival: Label,
    ready: Label,
}

/// The ride a walk follows: its boarding and alighting connections, or none
/// for a walk from the origin.
type Ride = Option<(i32, i32)>;

fn walk_from(engine: &Engine, state: &mut State, round: u8, stop: usize, arrival_s: i32, ride: Ride) {
    let (kind, board, alight) = match ride {
        Some((board, alight)) => (PARENT_WALK_AFTER_RIDE, board, alight),
        None => (PARENT_WALK_FROM_ORIGIN, -1, -1),
    };

    for link in engine.link_offsets[stop]..engine.link_offsets[stop + 1] {
        let target = engine.link_to[link] as usize;
        let duration_s = engine.link_duration_s[link];
        let parent = (kind, board, alight, duration_s, round);
        state.arrival.improve(target, arrival_s + duration_s, parent);
        state.ready.improve(target, arrival_s + duration_s, parent);
    }
}

fn scan_round(engine: &Engine, previous: &State, state: &mut State, round: u8, departure_s: i32, target: usize) {
    let connections = &engine.connections;
    let mut boarded_at = vec![-1i32; engine.trip_count];

    for index in engine.first_connection(departure_s)..connections.departure_s.len() {
        let departure = connections.departure_s[index];

        if departure >= state.arrival.time_s[target] {
            break;
        }

        let trip = connections.trip[index] as usize;
        let departure_stop = connections.departure_stop[index] as usize;
        let is_boardable = connections.boarding[index] && previous.ready.time_s[departure_stop] <= departure;

        if boarded_at[trip] < 0 && is_boardable {
            boarded_at[trip] = index as i32;
        }

        let is_alighting = boarded_at[trip] >= 0 && connections.alighting[index];
        let arrival_stop = connections.arrival_stop[index] as usize;
        let arrival_s = connections.arrival_s[index];

        if is_alighting && arrival_s < state.arrival.time_s[arrival_stop] {
            let parent = (PARENT_RIDE, boarded_at[trip], index as i32, 0, round);
            state.arrival.improve(arrival_stop, arrival_s, parent);
            state.ready.improve(arrival_stop, arrival_s + engine.minimum_transfer_s, parent);
            walk_from(engine, state, round, arrival_stop, arrival_s, Some((boarded_at[trip], index as i32)));
        }
    }
}

fn legs(engine: &Engine, rounds: &[State], round_index: usize, source: usize, target: usize) -> Vec<Leg> {
    let connections = &engine.connections;
    let mut result = Vec::new();
    let mut stop = target;
    let mut current = round_index;
    let mut use_ready = false;

    for _step in 0..LEG_COUNT_MAX {
        let label = if use_ready { &rounds[current].ready } else { &rounds[current].arrival };
        let kind = label.kind[stop];

        if kind == PARENT_NONE {
            result.reverse();
            return result;
        }

        if kind == PARENT_WALK_FROM_ORIGIN {
            result.push(Leg::Walk { from_stop: source as u32, to_stop: stop as u32, duration_s: label.c[stop] });
            result.reverse();
            return result;
        }

        let board = label.a[stop] as u32;
        let alight = label.b[stop] as u32;

        if kind == PARENT_WALK_AFTER_RIDE {
            let from_stop = connections.arrival_stop[alight as usize];
            result.push(Leg::Walk { from_stop, to_stop: stop as u32, duration_s: label.c[stop] });
        }

        result.push(Leg::Ride { board_connection: board, alight_connection: alight });
        current = label.round[stop] as usize - 1;
        stop = connections.departure_stop[board as usize] as usize;
        use_ready = true;
    }

    panic!("a journey has more legs than its rounds allow");
}

/// The Pareto frontier of journeys from `source` to `target` leaving at or
/// after `departure_s`, fewest changes first.
pub fn route(engine: &Engine, source: usize, target: usize, departure_s: i32) -> Vec<Journey> {
    let mut origin = State { arrival: Label::new(engine.stop_count), ready: Label::new(engine.stop_count) };
    origin.arrival.time_s[source] = departure_s;
    origin.ready.time_s[source] = departure_s;
    walk_from(engine, &mut origin, 0, source, departure_s, None);

    let mut frontier = Vec::new();
    let mut best_s = origin.arrival.time_s[target];
    let mut rounds = vec![origin];

    if best_s < UNREACHED {
        frontier.push(Journey { arrival_s: best_s, changes: 0, legs: legs(engine, &rounds, 0, source, target) });
    }

    for round_index in 1..=ROUNDS_MAX {
        let mut state = rounds[round_index - 1].clone();
        scan_round(engine, &rounds[round_index - 1], &mut state, round_index as u8, departure_s, target);
        rounds.push(state);
        let arrival_s = rounds[round_index].arrival.time_s[target];

        if arrival_s < best_s {
            best_s = arrival_s;
            let journey_legs = legs(engine, &rounds, round_index, source, target);
            let rides = journey_legs.iter().filter(|leg| matches!(leg, Leg::Ride { .. })).count() as u32;
            frontier.push(Journey { arrival_s, changes: rides.saturating_sub(1), legs: journey_legs });
        }
    }

    frontier
}

/// A frontier as the `i32` values the exports hand back: the journey count,
/// then per journey its arrival, changes, and leg count, and per leg its kind
/// (1 ride, 2 walk) and three values: board and alight connection and 0, or
/// from stop, to stop, and duration.
pub fn encode(frontier: &[Journey]) -> Vec<i32> {
    let mut values = vec![frontier.len() as i32];

    for journey in frontier {
        values.extend([journey.arrival_s, journey.changes as i32, journey.legs.len() as i32]);

        for leg in &journey.legs {
            match leg {
                Leg::Ride { board_connection, alight_connection } => {
                    values.extend([1, *board_connection as i32, *alight_connection as i32, 0]);
                }
                Leg::Walk { from_stop, to_stop, duration_s } => {
                    values.extend([2, *from_stop as i32, *to_stop as i32, *duration_s]);
                }
            }
        }
    }

    values
}

thread_local! {
    static ENGINE: RefCell<Engine> = RefCell::new(Engine::default());
    static RESULT: RefCell<Vec<i32>> = const { RefCell::new(Vec::new()) };
}

/// Reserves `len` bytes of linear memory for a caller to copy a file into.
#[no_mangle]
pub extern "C" fn alloc(len: usize) -> *mut u8 {
    let mut buffer = Vec::<u8>::with_capacity(len);
    let pointer = buffer.as_mut_ptr();
    std::mem::forget(buffer);
    pointer
}

/// Frees `len` bytes reserved by `alloc` at `pointer`.
///
/// # Safety
/// `pointer` and `len` must be those of one earlier `alloc`.
#[no_mangle]
pub unsafe extern "C" fn dealloc(pointer: *mut u8, len: usize) {
    drop(Vec::from_raw_parts(pointer, 0, len));
}

fn status(result: Result<(), Refusal>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(refusal) => refusal as i32,
    }
}

/// # Safety
/// `pointer` must hold `len` bytes the caller wrote after an `alloc`.
unsafe fn file<'a>(pointer: *const u8, len: usize) -> &'a [u8] {
    std::slice::from_raw_parts(pointer, len)
}

/// Starts a new engine with `minimum_transfer_s`, dropping the one held.
#[no_mangle]
pub extern "C" fn reset(minimum_transfer_s: i32) {
    ENGINE.with(|engine| *engine.borrow_mut() = Engine { minimum_transfer_s, ..Engine::default() });
}

/// # Safety
/// As `file`.
#[no_mangle]
pub unsafe extern "C" fn add_stops(pointer: *const u8, len: usize) -> i32 {
    ENGINE.with(|engine| status(engine.borrow_mut().set_stops(file(pointer, len))))
}

/// # Safety
/// As `file`.
#[no_mangle]
pub unsafe extern "C" fn add_transfers(pointer: *const u8, len: usize) -> i32 {
    ENGINE.with(|engine| status(engine.borrow_mut().set_transfers(file(pointer, len))))
}

/// # Safety
/// As `file`.
#[no_mangle]
pub unsafe extern "C" fn add_connections(pointer: *const u8, len: usize) -> i32 {
    ENGINE.with(|engine| status(engine.borrow_mut().add_connections(file(pointer, len))))
}

/// Builds what the engine derives once every file is added.
#[no_mangle]
pub extern "C" fn finish() {
    ENGINE.with(|engine| engine.borrow_mut().finish());
}

/// Routes one query and returns the length of its encoded result.
#[no_mangle]
pub extern "C" fn query(source: u32, target: u32, departure_s: i32) -> usize {
    let frontier = ENGINE.with(|engine| route(&engine.borrow(), source as usize, target as usize, departure_s));
    RESULT.with(|result| {
        *result.borrow_mut() = encode(&frontier);
        result.borrow().len()
    })
}

/// The address of the last query's encoded result.
#[no_mangle]
pub extern "C" fn result_ptr() -> *const i32 {
    RESULT.with(|result| result.borrow().as_ptr())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../test/fixtures/routing/v1/");

    fn fixture(kind: &str) -> Vec<u8> {
        std::fs::read(format!("{FIXTURES}{kind}.bin")).expect("the shared fixture exists")
    }

    // Reads the shared snapshot fixtures the Elixir encoder writes, the files
    // the JavaScript reader decodes too.
    #[test]
    fn reads_the_shared_fixtures() {
        let mut engine = Engine::default();
        assert_eq!(engine.set_stops(&fixture("stops")), Ok(()));
        assert_eq!(engine.set_transfers(&fixture("transfers")), Ok(()));
        assert_eq!(engine.add_connections(&fixture("connections")), Ok(()));
        assert_eq!(engine.stop_count, 3);
        assert_eq!(engine.connections.departure_s, vec![600, 21_600, 21_780, 90_000]);
        assert_eq!(engine.connections.boarding, vec![true, true, false, false]);
        assert_eq!(engine.connections.alighting, vec![true, false, true, false]);
        assert_eq!(engine.link_duration_s, vec![95, 95]);
    }

    #[test]
    fn refuses_a_file_cut_short() {
        let file = fixture("connections");
        let mut engine = Engine::default();
        assert_eq!(engine.add_connections(&file[..file.len() - 1]), Err(Refusal::InvalidLength));
    }

    #[test]
    fn refuses_a_file_of_another_kind() {
        let mut engine = Engine::default();
        assert_eq!(engine.add_connections(&fixture("stops")), Err(Refusal::InvalidHeader));
    }
}
