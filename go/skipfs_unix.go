//go:build aix || android || dragonfly || linux || darwin
// +build aix android dragonfly linux darwin

package main

import "syscall"

const (
	ADFS_SUPER_MAGIC      = 0xadf5
	AFFS_SUPER_MAGIC      = 0xADFF
	BDEVFS_MAGIC          = 0x62646576
	BEFS_SUPER_MAGIC      = 0x42465331
	BFS_MAGIC             = 0x1BADFACE
	BINFMTFS_MAGIC        = 0x42494e4d
	BTRFS_SUPER_MAGIC     = 0x9123683E
	CGROUP_SUPER_MAGIC    = 0x27e0eb
	SMB1_MAGIC_NUMBER     = 0xFF534D42
	SMB2_MAGIC_NUMBER     = 0xFE534D42
	SMB3_MAGIC_NUMBER     = 0xFD534D42
	CODA_SUPER_MAGIC      = 0x73757245
	COH_SUPER_MAGIC       = 0x012FF7B7
	CRAMFS_MAGIC          = 0x28cd3d45
	DEBUGFS_MAGIC         = 0x64626720
	DEVFS_SUPER_MAGIC     = 0x1373
	DEVPTS_SUPER_MAGIC    = 0x1cd1
	EFIVARFS_MAGIC        = 0xde5e81e4
	EFS_SUPER_MAGIC       = 0x00414A53
	EXT_SUPER_MAGIC       = 0x137D
	EXT2_OLD_SUPER_MAGIC  = 0xEF51
	EXT2_SUPER_MAGIC      = 0xEF53
	EXT3_SUPER_MAGIC      = 0xEF53
	EXT4_SUPER_MAGIC      = 0xEF53
	FUSE_SUPER_MAGIC      = 0x65735546
	FUTEXFS_SUPER_MAGIC   = 0xBAD1DEA
	HFS_SUPER_MAGIC       = 0x4244
	HOSTFS_SUPER_MAGIC    = 0x00c0ffee
	HPFS_SUPER_MAGIC      = 0xF995E849
	HUGETLBFS_MAGIC       = 0x958458f6
	ISOFS_SUPER_MAGIC     = 0x9660
	JFFS2_SUPER_MAGIC     = 0x72b6
	JFS_SUPER_MAGIC       = 0x3153464a
	MINIX_SUPER_MAGIC     = 0x137F /* orig. minix */
	MINIX_SUPER_MAGIC2    = 0x138F /* 30 char minix */
	MINIX2_SUPER_MAGIC    = 0x2468 /* minix V2 */
	MINIX2_SUPER_MAGIC2   = 0x2478 /* minix V2, 30 char names */
	MINIX3_SUPER_MAGIC    = 0x4d5a /* minix V3 fs, 60 char names */
	MQUEUE_MAGIC          = 0x19800202
	MSDOS_SUPER_MAGIC     = 0x4d44
	NCP_SUPER_MAGIC       = 0x564c
	NFS_SUPER_MAGIC       = 0x6969
	NILFS_SUPER_MAGIC     = 0x3434
	NTFS_SB_MAGIC         = 0x5346544e
	OPENPROM_SUPER_MAGIC  = 0x9fa1
	PIPEFS_MAGIC          = 0x50495045
	PROC_SUPER_MAGIC      = 0x9fa0
	PSTOREFS_MAGIC        = 0x6165676C
	QNX4_SUPER_MAGIC      = 0x002f
	QNX6_SUPER_MAGIC      = 0x68191122
	RAMFS_MAGIC           = 0x858458f6
	REISERFS_SUPER_MAGIC  = 0x52654973
	ROMFS_MAGIC           = 0x7275
	SELINUX_MAGIC         = 0xf97cff8c
	SMACK_MAGIC           = 0x43415d53
	SMB_SUPER_MAGIC       = 0x517B
	SOCKFS_MAGIC          = 0x534F434B
	SQUASHFS_MAGIC        = 0x73717368
	SYSFS_MAGIC           = 0x62656572
	SYSV2_SUPER_MAGIC     = 0x012FF7B6
	SYSV4_SUPER_MAGIC     = 0x012FF7B5
	TMPFS_MAGIC           = 0x01021994
	UDF_SUPER_MAGIC       = 0x15013346
	UFS_MAGIC             = 0x00011954
	USBDEVICE_SUPER_MAGIC = 0x9fa2
	V9FS_MAGIC            = 0x01021997
	VXFS_SUPER_MAGIC      = 0xa501FCF5
	XENFS_SUPER_MAGIC     = 0xabba1974
	XENIX_SUPER_MAGIC     = 0x012FF7B4
	XFS_SUPER_MAGIC       = 0x58465342
	_XIAFS_SUPER_MAGIC    = 0x012FD16D

	// AZ Special GPFS type
	GPFS_MAGIC = 0x47504653

	// Taken from vmblock.tar:vmblock-only/linux/filesystem.h
	VMBLOCK_SUPER_MAGIC = 0xabababab

	// Taken from linux/fs/ocfs2/ocfs2_fs.h
	OCFS2_SUPER_MAGIC = 0x7461636f

	// Taken from linux/fs/afs/super.c
	AFS_FS_MAGIC = 0x6B414653

	// Taken from linux/fs/ceph/super.h
	CEPH_SUPER_MAGIC = 0x00c36400

	// OpenAFS seems to use yet another constant.
	// Taken from openafs-1.6.18.2/src/afs/LINUX/osi_vfsops.c
	OPENAFS_FS_MAGIC = 0x5346414F
)

func SkipFilesystem(path string) bool {
	var buf syscall.Statfs_t
	if err := syscall.Statfs(path, &buf); err != nil {
		return false
	}
	switch uint32(buf.Type) {
	case BDEVFS_MAGIC, BINFMTFS_MAGIC, CGROUP_SUPER_MAGIC,
		DEBUGFS_MAGIC, EFIVARFS_MAGIC, FUTEXFS_SUPER_MAGIC,
		HUGETLBFS_MAGIC, PIPEFS_MAGIC, SELINUX_MAGIC, SMACK_MAGIC,
		SYSFS_MAGIC, PROC_SUPER_MAGIC:
		// pseudo filesystems
		return true

	case AFS_FS_MAGIC, OPENAFS_FS_MAGIC, CEPH_SUPER_MAGIC,
		SMB1_MAGIC_NUMBER, SMB2_MAGIC_NUMBER, SMB3_MAGIC_NUMBER, CODA_SUPER_MAGIC, NCP_SUPER_MAGIC,
		NFS_SUPER_MAGIC, OCFS2_SUPER_MAGIC, SMB_SUPER_MAGIC,
		V9FS_MAGIC, VMBLOCK_SUPER_MAGIC, XENFS_SUPER_MAGIC,
		GPFS_MAGIC:
		// network filesystems
		return true

	default:
		return false
	}
}
