// SysV IPC constants shared between kernel and userspace

// IPC command/flag constants
pub const IPC_CREAT: i32 = 0o1000; // Create key if not exists
pub const IPC_EXCL: i32 = 0o2000; // Fail if key exists
pub const IPC_NOWAIT: i32 = 0o4000; // Return error on wait
pub const IPC_RMID: i32 = 0; // Remove resource
pub const IPC_SET: i32 = 1; // Set ipc_perm options
pub const IPC_STAT: i32 = 2; // Get ipc_perm options
pub const IPC_INFO: i32 = 3; // See ipcs
pub const IPC_PRIVATE: i32 = 0; // Private key (always create new)

// Shared memory flags
pub const SHM_RDONLY: u32 = 0o10000; // Attach read-only
pub const SHM_RND: u32 = 0o20000; // Round attach address to SHMLBA
pub const SHM_REMAP: u32 = 0o40000; // Take over region on attach
pub const SHM_EXEC: u32 = 0o100000; // Execution access

// Semaphore constants
pub const GETVAL: i32 = 12; // Get semval
pub const SETVAL: i32 = 16; // Set semval
pub const GETALL: i32 = 13; // Get all semval
pub const SETALL: i32 = 17; // Set all semval
pub const SEM_UNDO: i16 = 0x1000; // Undo on process exit

// Resource limits
pub const SHMMAX: usize = 0x2000000; // 32 MB max segment size
pub const SHMMIN: usize = 1; // 1 byte min
pub const SHMMNI: usize = 128; // Max segments (reduced for microkernel)
pub const SHMALL: usize = 0x200000; // Max total pages
pub const SEMMNI: usize = 128; // Max semaphore sets
pub const SEMMSL: usize = 250; // Max sems per set
pub const SEMOPM: usize = 32; // Max operations per semop (reduced)
pub const SEMVMX: usize = 32767; // Max semaphore value
pub const MSGMNI: usize = 128; // Max message queues
pub const MSGMAX: usize = 8192; // Max message size
pub const MSGMNB: usize = 16384; // Max queue bytes

// IPC permission structure (matches Linux struct ipc_perm layout)
pub const IpcPermUser = extern struct {
    key: i32, // Key supplied to xxxget
    uid: u32, // Owner's user ID
    gid: u32, // Owner's group ID
    cuid: u32, // Creator's user ID
    cgid: u32, // Creator's group ID
    mode: u16, // Permissions (lower 9 bits)
    seq: u16, // Sequence number
};

// shmid_ds structure (for IPC_STAT)
pub const ShmidDs = extern struct {
    shm_perm: IpcPermUser,
    shm_segsz: usize, // Size of segment in bytes
    shm_atime: i64, // Last attach time
    shm_dtime: i64, // Last detach time
    shm_ctime: i64, // Last change time
    shm_cpid: u32, // PID of creator
    shm_lpid: u32, // PID of last shmat/shmdt
    shm_nattch: u32, // Number of current attaches
    _pad: u32 = 0,
};

// semid_ds structure
pub const SemidDs = extern struct {
    sem_perm: IpcPermUser,
    sem_otime: i64, // Last semop time
    sem_ctime: i64, // Last change time
    sem_nsems: u32, // Number of semaphores in set
    _pad: u32 = 0,
};

// sembuf structure (for semop)
pub const SemBuf = extern struct {
    sem_num: u16, // Semaphore index in set
    sem_op: i16, // Operation value
    sem_flg: i16, // Flags (IPC_NOWAIT, SEM_UNDO)
    _pad: u16 = 0,
};

// msqid_ds structure
pub const MsqidDs = extern struct {
    msg_perm: IpcPermUser,
    msg_stime: i64, // Last msgsnd time
    msg_rtime: i64, // Last msgrcv time
    msg_ctime: i64, // Last change time
    msg_cbytes: usize, // Current bytes in queue
    msg_qnum: usize, // Number of messages
    msg_qbytes: usize, // Max bytes in queue
    msg_lspid: u32, // PID of last msgsnd
    msg_lrpid: u32, // PID of last msgrcv
};

// msgbuf header (type field only, data follows)
pub const MsgBufHeader = extern struct {
    mtype: i64, // Message type (must be > 0)
};
