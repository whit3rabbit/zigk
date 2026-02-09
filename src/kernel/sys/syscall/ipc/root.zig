const shm = @import("shm.zig");
pub const sys_shmget = shm.sys_shmget;
pub const sys_shmat = shm.sys_shmat;
pub const sys_shmdt = shm.sys_shmdt;
pub const sys_shmctl = shm.sys_shmctl;

const sem = @import("sem.zig");
pub const sys_semget = sem.sys_semget;
pub const sys_semop = sem.sys_semop;
pub const sys_semctl = sem.sys_semctl;
