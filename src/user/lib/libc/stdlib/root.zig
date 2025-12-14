// Standard library module aggregator
//
// Re-exports all stdlib functions from submodules.

const math = @import("math.zig");
const convert = @import("convert.zig");
const random = @import("random.zig");
const process = @import("process.zig");
const env = @import("env.zig");
const sort = @import("sort.zig");

// Math utilities
pub const abs = math.abs;
pub const labs = math.labs;
pub const llabs = math.llabs;
pub const div = math.div;
pub const ldiv = math.ldiv;
pub const lldiv = math.lldiv;
pub const div_t = math.div_t;
pub const ldiv_t = math.ldiv_t;
pub const lldiv_t = math.lldiv_t;

// String to number conversion
pub const atoi = convert.atoi;
pub const atol = convert.atol;
pub const atoll = convert.atoll;
pub const atof = convert.atof;
pub const strtol = convert.strtol;
pub const strtoul = convert.strtoul;
pub const strtoll = convert.strtoll;
pub const strtoull = convert.strtoull;
pub const strtod = convert.strtod;
pub const strtof = convert.strtof;

// Random numbers
pub const rand = random.rand;
pub const srand = random.srand;
pub const random_fn = random.random;
pub const srandom = random.srandom;
pub const RAND_MAX = random.RAND_MAX;

// Process control
pub const exit = process.exit;
pub const abort = process.abort;
pub const _Exit = process._Exit;
pub const _exit = process._exit;
pub const atexit = process.atexit;
pub const system = process.system;
pub const EXIT_SUCCESS = process.EXIT_SUCCESS;
pub const EXIT_FAILURE = process.EXIT_FAILURE;

// Environment
pub const getenv = env.getenv;
pub const setenv = env.setenv;
pub const unsetenv = env.unsetenv;
pub const putenv = env.putenv;

// Filesystem stubs
pub const mkdir = env.mkdir;
pub const rmdir = env.rmdir;
pub const chdir = env.chdir;
pub const getcwd = env.getcwd;

// Sorting and searching
pub const qsort = sort.qsort;
pub const bsearch = sort.bsearch;
pub const lfind = sort.lfind;
