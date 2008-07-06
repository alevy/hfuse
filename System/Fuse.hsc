-----------------------------------------------------------------------------
-- |
-- Module      :  System.Fuse
-- Copyright   :  (c) Jérémy Bobbio
-- License     :  BSD-style
-- 
-- Maintainer  :  jeremy.bobbio@etu.upmc.fr
-- Stability   :  experimental
-- Portability :  GHC 6.4
--
-- A binding for the FUSE (Filesystem in USErspace) library
-- (<http://fuse.sourceforge.net/>), which allows filesystems to be implemented
-- as userspace processes.
--
-- The binding tries to follow as much as possible current Haskell POSIX
-- interface in "System.Posix.Files" and "System.Posix.Directory".
--
-- FUSE uses POSIX threads, so any Haskell application using this library must
-- be linked against a threaded runtime system (eg. using the @threaded@ GHC
-- option).
--
-----------------------------------------------------------------------------
module System.Fuse
    ( -- * Using FUSE

      -- $intro

      module Foreign.C.Error
    , FuseOperations(..)
    , defaultFuseOps
    , fuseMain -- :: FuseOperations -> (Exception -> IO Errno) -> IO ()
    , defaultExceptionHandler -- :: Exception -> IO Errno
      -- * Operations datatypes
    , FileStat(..)
    , EntryType(..)
    , FileSystemStats(..)
    , SyncType(..)
      -- * FUSE Context
    , getFuseContext -- :: IO FuseContext
    , FuseContext(fuseCtxUserID, fuseCtxGroupID, fuseCtxProcessID)
      -- * File modes
    , entryTypeToFileMode -- :: EntryType -> FileMode
    , OpenMode(..)
    , OpenFileFlags(..)
    , intersectFileModes -- :: FileMode
    , unionFileModes -- :: FileMode
    ) where

import Prelude hiding ( Read )

import Control.Exception as E( Exception, handle, finally )
import qualified Data.ByteString.Char8    as B
import qualified Data.ByteString.Internal as B
import qualified Data.ByteString.Unsafe   as B
import Foreign
import Foreign.C
import Foreign.C.Error
import Foreign.Marshal
import System.Environment ( getProgName, getArgs )
import System.IO ( hPutStrLn, stderr )
import System.Posix.Types
import System.Posix.Files ( accessModes, intersectFileModes, unionFileModes )
import System.Posix.IO ( OpenMode(..), OpenFileFlags(..) )

-- TODO: FileMode -> Permissions
-- TODO: Arguments !
-- TODO: implement binding to fuse_invalidate
-- TODO: bind fuse_*xattr

#define FUSE_USE_VERSION 26

#include <sys/statfs.h>
#include <dirent.h>
#include <fuse.h>
#include <fcntl.h>

#include "fuse_wrappers.h"

{- $intro
'FuseOperations' contains a field for each filesystem operations that can be called
by FUSE. Think like if you were implementing a file system inside the Linux kernel.

Each actions must return a POSIX error code, also called 'Errno' reflecting
operation result. For actions not using 'Either', you should return 'eOK' in case
of success.

Read and writes are done with Haskell 'ByteString' type.

-}

{-  All operations should return the negated error value (-errno) on
      error.
-}

{- | Used by 'fuseGetFileStat'.  Corresponds to @struct stat@ from @stat.h@;
     @st_dev@, @st_ino@ and @st_blksize@ are omitted, since (from the libfuse
     documentation): \"the @st_dev@ and @st_blksize@ fields are ignored.  The
     @st_ino@ field is ignored except if the use_ino mount option is given.\"

     /TODO: at some point the inode field will probably be needed./
-}
data FileStat = FileStat { statEntryType :: EntryType
                         , statFileMode :: FileMode
                         , statLinkCount :: LinkCount
                         , statFileOwner :: UserID
                         , statFileGroup :: GroupID
                         , statSpecialDeviceID :: DeviceID
                         , statFileSize :: FileOffset
                         , statBlocks :: Integer
                         , statAccessTime :: EpochTime
                         , statModificationTime :: EpochTime
                         , statStatusChangeTime :: EpochTime
                         }
    deriving Show

{- FIXME: I don't know how to determine the alignment of struct stat without
 - making unportable assumptions about the order of elements within it.  Hence,
 - FileStat is not an instance of Storable.  But it should be, rather than this
 - next function existing!
 -}

fileStatToCStat :: FileStat -> Ptr CStat -> IO ()
fileStatToCStat stat pStat = do
    let mode = (entryTypeToFileMode (statEntryType stat)
             `unionFileModes`
               (statFileMode stat `intersectFileModes` accessModes))
    let block_count = (fromIntegral (statBlocks stat) :: (#type blkcnt_t))
    (#poke struct stat, st_mode)   pStat mode
    (#poke struct stat, st_nlink)  pStat (statLinkCount  stat)
    (#poke struct stat, st_uid)    pStat (statFileOwner  stat)
    (#poke struct stat, st_gid)    pStat (statFileGroup  stat)
    (#poke struct stat, st_rdev)   pStat (statSpecialDeviceID stat)
    (#poke struct stat, st_size)   pStat (statFileSize   stat)
    (#poke struct stat, st_blocks) pStat block_count
    (#poke struct stat, st_atime)  pStat (statAccessTime stat)
    (#poke struct stat, st_mtime)  pStat (statModificationTime stat)
    (#poke struct stat, st_ctime)  pStat (statStatusChangeTime stat)


-- | The Unix type of a node in the filesystem.
data EntryType
    = Unknown            -- ^ Unknown entry type
    | NamedPipe
    | CharacterSpecial
    | Directory
    | BlockSpecial
    | RegularFile
    | SymbolicLink
    | Socket
      deriving(Show)

entryTypeToDT :: EntryType -> Int
entryTypeToDT Unknown          = (#const DT_UNKNOWN)
entryTypeToDT NamedPipe        = (#const DT_FIFO)
entryTypeToDT CharacterSpecial = (#const DT_CHR)
entryTypeToDT Directory        = (#const DT_DIR)
entryTypeToDT BlockSpecial     = (#const DT_BLK)
entryTypeToDT RegularFile      = (#const DT_REG)
entryTypeToDT SymbolicLink     = (#const DT_LNK)
entryTypeToDT Socket           = (#const DT_SOCK)

fileTypeModes :: FileMode
fileTypeModes = (#const S_IFMT)

blockSpecialMode :: FileMode
blockSpecialMode = (#const S_IFBLK)

characterSpecialMode :: FileMode
characterSpecialMode = (#const S_IFCHR)

namedPipeMode :: FileMode
namedPipeMode = (#const S_IFIFO)

regularFileMode :: FileMode
regularFileMode = (#const S_IFREG)

directoryMode :: FileMode
directoryMode = (#const S_IFDIR)

symbolicLinkMode :: FileMode
symbolicLinkMode = (#const S_IFLNK)

socketMode :: FileMode
socketMode = (#const S_IFSOCK)

-- | Converts an 'EntryType' into the corresponding POSIX 'FileMode'.
entryTypeToFileMode :: EntryType -> FileMode
entryTypeToFileMode Unknown          = 0
entryTypeToFileMode NamedPipe        = namedPipeMode
entryTypeToFileMode CharacterSpecial = characterSpecialMode
entryTypeToFileMode Directory        = directoryMode
entryTypeToFileMode BlockSpecial     = blockSpecialMode
entryTypeToFileMode RegularFile      = regularFileMode
entryTypeToFileMode SymbolicLink     = symbolicLinkMode
entryTypeToFileMode Socket           = socketMode

fileModeToEntryType :: FileMode -> EntryType
fileModeToEntryType mode
    | fileType == namedPipeMode        = NamedPipe
    | fileType == characterSpecialMode = CharacterSpecial
    | fileType == directoryMode        = Directory
    | fileType == blockSpecialMode     = BlockSpecial
    | fileType == regularFileMode      = RegularFile
    | fileType == symbolicLinkMode     = SymbolicLink
    | fileType == socketMode           = Socket
    where fileType = mode .&. (#const S_IFMT)

{-
    There is no create() operation, mknod() will be called for
    creation of all non directory, non symlink nodes.
-}

-- | Type used by the 'fuseGetFileSystemStats'.
data FileSystemStats = FileSystemStats
    { fsStatBlockSize :: Integer
      -- ^ Optimal transfer block size. FUSE default is 512.
    , fsStatBlockCount :: Integer
      -- ^ Total data blocks in file system.
    , fsStatBlocksFree :: Integer
      -- ^ Free blocks in file system.
    , fsStatBlocksAvailable :: Integer
      -- ^ Free blocks available to non-superusers.
    , fsStatFileCount :: Integer
      -- ^ Total file nodes in file system.
    , fsStatFilesFree :: Integer
      -- ^ Free file nodes in file system.
    , fsStatMaxNameLength :: Integer
      -- ^ Maximum length of filenames. FUSE default is 255.
    }


-- | Used by 'fuseSynchronizeFile' and 'fuseSynchronizeDirectory'.
data SyncType
    = FullSync
    -- ^ Synchronize all in-core parts of a file to disk: file content and
    -- metadata.
    | DataSync
    -- ^ Synchronize only the file content.
    deriving (Eq, Enum)


-- | Returned by 'getFuseContext'.
data FuseContext = FuseContext
    { fuseCtxUserID :: UserID
    , fuseCtxGroupID :: GroupID
    , fuseCtxProcessID :: ProcessID
    }

-- | Returns the context of the program doing the current FUSE call.
getFuseContext :: IO FuseContext
getFuseContext =
    do pCtx <- fuse_get_context
       userID <- (#peek struct fuse_context, uid) pCtx
       groupID <- (#peek struct fuse_context, gid) pCtx
       processID <- (#peek struct fuse_context, pid) pCtx
       return $ FuseContext { fuseCtxUserID = userID
                            , fuseCtxGroupID = groupID
                            , fuseCtxProcessID = processID
                            }

-- | This record, given to 'fuseMain', binds each required file system
--   operations.
--
--   Each field is named against 'System.Posix' names. Matching Linux system
--   calls are also given as a reference.
--
--   @fh@ is the file handle type returned by 'fuseOpen' and subsequently passed
--   to all other file operations.
data FuseOperations fh = FuseOperations
      { -- | Implements 'System.Posix.Files.getSymbolicLinkStatus' operation
        --   (POSIX @lstat(2)@).
        fuseGetFileStat :: FilePath -> IO (Either Errno FileStat),

        -- | Implements 'System.Posix.Files.readSymbolicLink' operation (POSIX
        --   @readlink(2)@).  The returned 'FilePath' might be truncated
        --   depending on caller buffer size.
        fuseReadSymbolicLink :: FilePath -> IO (Either Errno FilePath),

        -- | Implements 'System.Posix.Files.createDevice' (POSIX @mknod(2)@).
        --   This function will also be called for regular file creation.
        fuseCreateDevice :: FilePath -> EntryType -> FileMode
                         -> DeviceID -> IO Errno,

        -- | Implements 'System.Posix.Directory.createDirectory' (POSIX
        --   @mkdir(2)@).
        fuseCreateDirectory :: FilePath -> FileMode -> IO Errno,

        -- | Implements 'System.Posix.Files.removeLink' (POSIX @unlink(2)@).
        fuseRemoveLink :: FilePath -> IO Errno,

        -- | Implements 'System.Posix.Directory.removeDirectory' (POSIX
        --   @rmdir(2)@).
        fuseRemoveDirectory :: FilePath -> IO Errno,

        -- | Implements 'System.Posix.Files.createSymbolicLink' (POSIX
        --   @symlink(2)@).
        fuseCreateSymbolicLink :: FilePath -> FilePath -> IO Errno,

        -- | Implements 'System.Posix.Files.rename' (POSIX @rename(2)@).
        fuseRename :: FilePath -> FilePath -> IO Errno,

        -- | Implements 'System.Posix.Files.createLink' (POSIX @link(2)@).
        fuseCreateLink :: FilePath -> FilePath -> IO Errno,

        -- | Implements 'System.Posix.Files.setFileMode' (POSIX @chmod(2)@).
        fuseSetFileMode :: FilePath -> FileMode -> IO Errno,

        -- | Implements 'System.Posix.Files.setOwnerAndGroup' (POSIX
        --   @chown(2)@).
        fuseSetOwnerAndGroup :: FilePath -> UserID -> GroupID -> IO Errno,

        -- | Implements 'System.Posix.Files.setFileSize' (POSIX @truncate(2)@).
        fuseSetFileSize :: FilePath -> FileOffset -> IO Errno,

        -- | Implements 'System.Posix.Files.setFileTimes'
        --   (POSIX @utime(2)@).
        fuseSetFileTimes :: FilePath -> EpochTime -> EpochTime -> IO Errno,

        -- | Implements 'System.Posix.Files.openFd' (POSIX @open(2)@).  On
        --   success, returns 'Right' of a filehandle-like value that will be
        --   passed to future file operations; on failure, returns 'Left' of the
        --   appropriate 'Errno'.
        --
        --   No creation, exclusive access or truncating flags will be passed.
        --   This should check that the operation is permitted for the given
        --   flags.
        fuseOpen :: FilePath -> OpenMode -> OpenFileFlags -> IO (Either Errno fh),

        -- | Implements Unix98 @pread(2)@. It differs from
        --   'System.Posix.Files.fdRead' by the explicit 'FileOffset' argument.
        --   The @fuse.h@ documentation stipulates that this \"should return
        --   exactly the number of bytes requested except on EOF or error,
        --   otherwise the rest of the data will be substituted with zeroes.\"
        fuseRead :: FilePath -> fh -> ByteCount -> FileOffset
                 -> IO (Either Errno B.ByteString),

        -- | Implements Unix98 @pwrite(2)@. It differs
        --   from 'System.Posix.Files.fdWrite' by the explicit 'FileOffset' argument.
        fuseWrite :: FilePath -> fh -> B.ByteString -> FileOffset
                  -> IO (Either Errno ByteCount),

        -- | Implements @statfs(2)@.
        fuseGetFileSystemStats :: String -> IO (Either Errno FileSystemStats),

        -- | Called when @close(2)@ has been called on an open file.
        --   Note: this does not mean that the file is released.  This function may be
        --   called more than once for each @open(2)@.  The return value is passed on
        --   to the @close(2)@ system call.
        fuseFlush :: FilePath -> fh -> IO Errno,

        -- | Called when an open file has all file descriptors closed and all
        -- memory mappings unmapped.  For every @open@ call there will be
        -- exactly one @release@ call with the same flags.  It is possible to
        -- have a file opened more than once, in which case only the last
        -- release will mean that no more reads or writes will happen on the
        -- file.
        fuseRelease :: FilePath -> fh -> IO (),

        -- | Implements @fsync(2)@.
        fuseSynchronizeFile :: FilePath -> SyncType -> IO Errno,

        -- | Implements @opendir(3)@.  This method should check if the open
        --   operation is permitted for this directory.
        fuseOpenDirectory :: FilePath -> IO Errno,

        -- | Implements @readdir(3)@.  The entire contents of the directory
        --   should be returned as a list of tuples (corresponding to the first
        --   mode of operation documented in @fuse.h@).
        fuseReadDirectory :: FilePath -> IO (Either Errno [(FilePath, FileStat)]),

        -- | Implements @closedir(3)@.
        fuseReleaseDirectory :: FilePath -> IO Errno,

        -- | Synchronize the directory's contents; analogous to
        --   'fuseSynchronizeFile'.
        fuseSynchronizeDirectory :: FilePath -> SyncType -> IO Errno,

        -- | Check file access permissions; this will be called for the
        --   access() system call.  If the @default_permissions@ mount option
        --   is given, this method is not called.  This method is also not
        --   called under Linux kernel versions 2.4.x
        fuseAccess :: FilePath -> Int -> IO Errno, -- FIXME present a nicer type to Haskell

        -- | Initializes the filesystem.  This is called before all other
        --   operations.
        fuseInit :: IO (),

        -- | Called on filesystem exit to allow cleanup.
        fuseDestroy :: IO ()
      }

-- | Empty \/ default versions of the FUSE operations.
defaultFuseOps :: FuseOperations fh
defaultFuseOps =
    FuseOperations { fuseGetFileStat = \_ -> return (Left eNOSYS)
                   , fuseReadSymbolicLink = \_ -> return (Left eNOSYS)
                   , fuseCreateDevice = \_ _ _ _ ->  return eNOSYS
                   , fuseCreateDirectory = \_ _ -> return eNOSYS
                   , fuseRemoveLink = \_ -> return eNOSYS
                   , fuseRemoveDirectory = \_ -> return eNOSYS
                   , fuseCreateSymbolicLink = \_ _ -> return eNOSYS
                   , fuseRename = \_ _ -> return eNOSYS
                   , fuseCreateLink = \_ _ -> return eNOSYS
                   , fuseSetFileMode = \_ _ -> return eNOSYS
                   , fuseSetOwnerAndGroup = \_ _ _ -> return eNOSYS
                   , fuseSetFileSize = \_ _ -> return eNOSYS
                   , fuseSetFileTimes = \_ _ _ -> return eNOSYS
                   , fuseOpen =   \_ _ _   -> return (Left eNOSYS)
                   , fuseRead =   \_ _ _ _ -> return (Left eNOSYS)
                   , fuseWrite =  \_ _ _ _ -> return (Left eNOSYS)
                   , fuseGetFileSystemStats = \_ -> return (Left eNOSYS)
                   , fuseFlush = \_ _ -> return eOK
                   , fuseRelease = \_ _ -> return ()
                   , fuseSynchronizeFile = \_ _ -> return eNOSYS
                   , fuseOpenDirectory = \_ -> return eNOSYS
                   , fuseReadDirectory = \_ -> return (Left eNOSYS)
                   , fuseReleaseDirectory = \_ -> return eNOSYS
                   , fuseSynchronizeDirectory = \_ _ -> return eNOSYS
                   , fuseAccess = \_ _ -> return eNOSYS
                   , fuseInit = return ()
                   , fuseDestroy = return ()
                   }


-- | Main function of FUSE.
-- This is all that has to be called from the @main@ function. On top of
-- the 'FuseOperations' record with filesystem implementation, you must give
-- an exception handler converting Haskell exceptions to 'Errno'.
-- 
-- This function does the following:
--
--   * parses command line options (@-d@, @-s@ and @-h@) ;
--
--   * passes all options after @--@ to the fusermount program ;
--
--   * mounts the filesystem by calling @fusermount@ ;
--
--   * installs signal handlers for 'System.Posix.Signals.keyboardSignal',
--     'System.Posix.Signals.lostConnection',
--     'System.Posix.Signals.softwareTermination' and
--     'System.Posix.Signals.openEndedPipe' ;
--
--   * registers an exit handler to unmount the filesystem on program exit ;
--
--   * registers the operations ;
--
--   * calls FUSE event loop.
fuseMain :: FuseOperations fh -> (Exception -> IO Errno) -> IO ()
fuseMain ops handler =
    allocaBytes (#size struct fuse_operations) $ \ pOps -> do
      mkGetAttr    wrapGetAttr    >>= (#poke struct fuse_operations, getattr)    pOps
      mkReadLink   wrapReadLink   >>= (#poke struct fuse_operations, readlink)   pOps 
      -- getdir is deprecated and thus unsupported
      (#poke struct fuse_operations, getdir)    pOps nullPtr
      mkMkNod      wrapMkNod      >>= (#poke struct fuse_operations, mknod)      pOps 
      mkMkDir      wrapMkDir      >>= (#poke struct fuse_operations, mkdir)      pOps 
      mkUnlink     wrapUnlink     >>= (#poke struct fuse_operations, unlink)     pOps 
      mkRmDir      wrapRmDir      >>= (#poke struct fuse_operations, rmdir)      pOps 
      mkSymLink    wrapSymLink    >>= (#poke struct fuse_operations, symlink)    pOps 
      mkRename     wrapRename     >>= (#poke struct fuse_operations, rename)     pOps 
      mkLink       wrapLink       >>= (#poke struct fuse_operations, link)       pOps 
      mkChMod      wrapChMod      >>= (#poke struct fuse_operations, chmod)      pOps 
      mkChOwn      wrapChOwn      >>= (#poke struct fuse_operations, chown)      pOps 
      mkTruncate   wrapTruncate   >>= (#poke struct fuse_operations, truncate)   pOps 
      -- TODO: Deprecated, use utimens() instead.
      mkUTime      wrapUTime      >>= (#poke struct fuse_operations, utime)      pOps 
      mkOpen       wrapOpen       >>= (#poke struct fuse_operations, open)       pOps 
      mkRead       wrapRead       >>= (#poke struct fuse_operations, read)       pOps 
      mkWrite      wrapWrite      >>= (#poke struct fuse_operations, write)      pOps 
      mkStatFS     wrapStatFS     >>= (#poke struct fuse_operations, statfs)     pOps
      mkFlush      wrapFlush      >>= (#poke struct fuse_operations, flush)      pOps
      mkRelease    wrapRelease    >>= (#poke struct fuse_operations, release)    pOps 
      mkFSync      wrapFSync      >>= (#poke struct fuse_operations, fsync)      pOps
      -- TODO: Implement these
      (#poke struct fuse_operations, setxattr)    pOps nullPtr
      (#poke struct fuse_operations, getxattr)    pOps nullPtr
      (#poke struct fuse_operations, listxattr)   pOps nullPtr
      (#poke struct fuse_operations, removexattr) pOps nullPtr
      mkOpenDir    wrapOpenDir    >>= (#poke struct fuse_operations, opendir)    pOps
      mkReadDir    wrapReadDir    >>= (#poke struct fuse_operations, readdir)    pOps
      mkReleaseDir wrapReleaseDir >>= (#poke struct fuse_operations, releasedir) pOps
      mkFSyncDir   wrapFSyncDir   >>= (#poke struct fuse_operations, fsyncdir)   pOps
      mkAccess     wrapAccess     >>= (#poke struct fuse_operations, access)     pOps
      mkInit       wrapInit       >>= (#poke struct fuse_operations, init)       pOps
      mkDestroy    wrapDestroy    >>= (#poke struct fuse_operations, destroy)    pOps
      prog <- getProgName
      args <- getArgs
      let allArgs = (prog:args)
          argc    = length allArgs
      withMany withCString allArgs $ \ pAddrs  ->
          withArray pAddrs $ \ pArgv ->
              do fuse_main_wrapper argc pArgv pOps
    where fuseHandler :: Exception -> IO CInt
          fuseHandler e = handler e >>= return . unErrno
          wrapGetAttr :: CGetAttr
          wrapGetAttr pFilePath pStat = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 eitherFileStat <- (fuseGetFileStat ops) filePath
                 case eitherFileStat of
                   Left (Errno errno) -> return (- errno)
                   Right stat         -> do fileStatToCStat stat pStat
                                            return okErrno

          wrapReadLink :: CReadLink
          wrapReadLink pFilePath pBuf bufSize = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 return (- unErrno eNOSYS)
                 eitherTarget <- (fuseReadSymbolicLink ops) filePath
                 case eitherTarget of
                   Left (Errno errno) -> return (- errno)
                   Right target ->
                   -- This will truncate target if it's longer than the buffer
                   -- can hold, which is correct according to fuse.h
                     do pokeCStringLen0 (pBuf, (fromIntegral bufSize)) target
                        return okErrno

          wrapMkNod :: CMkNod
          wrapMkNod pFilePath mode dev = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseCreateDevice ops) filePath
                                      (fileModeToEntryType mode) mode dev
                 return (- errno)
          wrapMkDir :: CMkDir
          wrapMkDir pFilePath mode = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseCreateDirectory ops) filePath mode
                 return (- errno)
          wrapUnlink :: CUnlink
          wrapUnlink pFilePath = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseRemoveLink ops) filePath
                 return (- errno)
          wrapRmDir :: CRmDir
          wrapRmDir pFilePath = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseRemoveDirectory ops) filePath
                 return (- errno)
          wrapSymLink :: CSymLink
          wrapSymLink pSource pDestination = handle fuseHandler $
              do source <- peekCString pSource
                 destination <- peekCString pDestination
                 (Errno errno) <- (fuseCreateSymbolicLink ops) source destination
                 return (- errno)
          wrapRename :: CRename
          wrapRename pOld pNew = handle fuseHandler $
              do old <- peekCString pOld
                 new <- peekCString pNew
                 (Errno errno) <- (fuseRename ops) old new
                 return (- errno)
          wrapLink :: CLink
          wrapLink pSource pDestination = handle fuseHandler $
              do source <- peekCString pSource
                 destination <- peekCString pDestination
                 (Errno errno) <- (fuseCreateLink ops) source destination
                 return (- errno)
          wrapChMod :: CChMod
          wrapChMod pFilePath mode = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseSetFileMode ops) filePath mode
                 return (- errno)
          wrapChOwn :: CChOwn
          wrapChOwn pFilePath uid gid = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseSetOwnerAndGroup ops) filePath uid gid
                 return (- errno)
          wrapTruncate :: CTruncate
          wrapTruncate pFilePath off = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseSetFileSize ops) filePath off
                 return (- errno)
          wrapUTime :: CUTime
          wrapUTime pFilePath pUTimBuf = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 accessTime <- (#peek struct utimbuf, actime) pUTimBuf
                 modificationTime <- (#peek struct utimbuf, modtime) pUTimBuf
                 (Errno errno) <- (fuseSetFileTimes ops) filePath
                                      accessTime modificationTime
                 return (- errno)
          wrapOpen :: COpen
          wrapOpen pFilePath pFuseFileInfo = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (flags :: CInt) <- (#peek struct fuse_file_info, flags) pFuseFileInfo
                 let append    = (#const O_APPEND)   .&. flags == (#const O_APPEND)
                     noctty    = (#const O_NOCTTY)   .&. flags == (#const O_NOCTTY)
                     nonBlock  = (#const O_NONBLOCK) .&. flags == (#const O_NONBLOCK)
                     how | (#const O_RDWR) .&. flags == (#const O_RDWR) = ReadWrite
                         | (#const O_WRONLY) .&. flags == (#const O_WRONLY) = WriteOnly
                         | otherwise = ReadOnly
                     openFileFlags = OpenFileFlags { append = append
                                                   , exclusive = False
                                                   , noctty = noctty
                                                   , nonBlock = nonBlock
                                                   , trunc = False
                                                   }
                 result <- (fuseOpen ops) filePath how openFileFlags
                 case result of
                    Left (Errno errno) -> return (- errno)
                    Right cval         -> do
                        sptr <- newStablePtr cval
                        (#poke struct fuse_file_info, fh) pFuseFileInfo $ castStablePtrToPtr sptr
                        return okErrno

          wrapRead :: CRead
          wrapRead pFilePath pBuf bufSiz off pFuseFileInfo = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 cVal <- getFH pFuseFileInfo
                 eitherRead <- (fuseRead ops) filePath cVal bufSiz off
                 case eitherRead of
                   Left (Errno errno) -> return (- errno)
                   Right bytes  -> 
                     do let len = fromIntegral bufSiz `min` B.length bytes
                        bsToBuf pBuf bytes len
                        return (fromIntegral len)
          wrapWrite :: CWrite
          wrapWrite pFilePath pBuf bufSiz off pFuseFileInfo = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 cVal <- getFH pFuseFileInfo
                 buf  <- B.packCStringLen (pBuf, fromIntegral bufSiz)
                 eitherBytes <- (fuseWrite ops) filePath cVal buf off
                 case eitherBytes of
                   Left  (Errno errno) -> return (- errno)
                   Right bytes         -> return (fromIntegral bytes)
          wrapStatFS :: CStatFS
          wrapStatFS pStr pStatFS = handle fuseHandler $
            do str <- peekCString pStr
               eitherStatFS <- (fuseGetFileSystemStats ops) str
               case eitherStatFS of
                 Left (Errno errno) -> return (- errno)
                 Right stat         ->
                   do (#poke struct statfs, f_bsize) pStatFS
                          (fromIntegral (fsStatBlockSize stat) :: (#type long))
                      (#poke struct statfs, f_blocks) pStatFS
                          (fromIntegral (fsStatBlockCount stat) :: (#type long))
                      (#poke struct statfs, f_bfree) pStatFS
                          (fromIntegral (fsStatBlocksFree stat) :: (#type long))
                      (#poke struct statfs, f_bavail) pStatFS
                          (fromIntegral (fsStatBlocksAvailable
                                             stat) :: (#type long))
                      (#poke struct statfs, f_files) pStatFS
                           (fromIntegral (fsStatFileCount stat) :: (#type long))
                      (#poke struct statfs, f_ffree) pStatFS
                          (fromIntegral (fsStatFilesFree stat) :: (#type long))
                      (#poke struct statfs, f_namelen) pStatFS
                          (fromIntegral (fsStatMaxNameLength stat) :: (#type long))
                      return 0
          wrapFlush :: CFlush
          wrapFlush pFilePath pFuseFileInfo = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 cVal     <- getFH pFuseFileInfo
                 (Errno errno) <- (fuseFlush ops) filePath cVal
                 return (- errno)
          wrapRelease :: CRelease
          wrapRelease pFilePath pFuseFileInfo = E.finally (handle fuseHandler $
              do filePath <- peekCString pFilePath
                 cVal     <- getFH pFuseFileInfo
                 -- TODO: deal with these flags?
--                 flags <- (#peek struct fuse_file_info, flags) pFuseFileInfo
                 (fuseRelease ops) filePath cVal
                 return 0) (delFH pFuseFileInfo)
          wrapFSync :: CFSync
          wrapFSync pFilePath isFullSync pFuseFileInfo = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseSynchronizeFile ops)
                                      filePath (toEnum isFullSync)
                 return (- errno)
          wrapOpenDir :: COpenDir
          wrapOpenDir pFilePath pFuseFileInfo = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 -- XXX: Should we pass flags from pFuseFileInfo?
                 (Errno errno) <- (fuseOpenDirectory ops) filePath
                 return (- errno)

          wrapReadDir :: CReadDir
          wrapReadDir pFilePath pBuf pFillDir off pFuseFileInfo =
            handle fuseHandler $ do
              filePath <- peekCString pFilePath
              let fillDir = mkFillDir pFillDir
              let filler :: (FilePath, FileStat) -> IO ()
                  filler (fileName, fileStat) =
                    withCString fileName $ \ pFileName ->
                      allocaBytes (#size struct stat) $ \ pFileStat ->
                        do fileStatToCStat fileStat pFileStat
                           fillDir pBuf pFileName pFileStat 0
                           -- Ignoring return value of pFillDir, namely 1 if
                           -- pBuff is full.
                           return ()
              eitherContents <- (fuseReadDirectory ops) filePath -- XXX fileinfo
              case eitherContents of
                Left (Errno errno) -> return (- errno)
                Right contents     -> mapM filler contents >> return okErrno

          wrapReleaseDir :: CReleaseDir
          wrapReleaseDir pFilePath pFuseFileInfo = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseReleaseDirectory ops) filePath
                 return (- errno)
          wrapFSyncDir :: CFSyncDir
          wrapFSyncDir pFilePath isFullSync pFuseFileInfo = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseSynchronizeDirectory ops)
                                      filePath (toEnum isFullSync)
                 return (- errno)
          wrapAccess :: CAccess
          wrapAccess pFilePath at = handle fuseHandler $
              do filePath <- peekCString pFilePath
                 (Errno errno) <- (fuseAccess ops) filePath (fromIntegral at)
                 return (- errno)
          wrapInit :: CInit
          wrapInit pFuseConnInfo =
            handle (\e -> hPutStrLn stderr (show e) >> return nullPtr) $
              do fuseInit ops
                 return nullPtr
          wrapDestroy :: CDestroy
          wrapDestroy _ = handle (\e -> hPutStrLn stderr (show e)) $
              do fuseDestroy ops

-- | Default exception handler.
-- Print the exception on error output and returns 'eFAULT'.
defaultExceptionHandler :: (Exception -> IO Errno)
defaultExceptionHandler e = hPutStrLn stderr (show e) >> return eFAULT


-----------------------------------------------------------------------------
-- Miscellaneous utilities

unErrno :: Errno -> CInt
unErrno (Errno errno) = errno

okErrno :: CInt
okErrno = unErrno eOK

pokeCStringLen :: CStringLen -> String -> IO ()
pokeCStringLen (pBuf, bufSize) src =
    pokeArray pBuf $ take bufSize $ map castCharToCChar src

pokeCStringLen0 :: CStringLen -> String -> IO ()
pokeCStringLen0 (pBuf, bufSize) src =
    pokeArray0 0 pBuf $ take (bufSize - 1) $ map castCharToCChar src

-----------------------------------------------------------------------------
-- C land

---
-- exported C called from Haskell
---  

data CFuseOperations
foreign import ccall threadsafe "fuse_wrappers.h fuse_main_wrapper"
    fuse_main_wrapper :: Int -> Ptr CString -> Ptr CFuseOperations -> IO ()

data StructFuse
foreign import ccall threadsafe "fuse.h fuse_get_context"
    fuse_get_context :: IO (Ptr StructFuse)

---
-- dynamic Haskell called from C
---

data CFuseFileInfo -- struct fuse_file_info
data CFuseConnInfo -- struct fuse_conn_info

data CStat -- struct stat
type CGetAttr = CString -> Ptr CStat -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkGetAttr :: CGetAttr -> IO (FunPtr CGetAttr)

type CReadLink = CString -> CString -> CSize -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkReadLink :: CReadLink -> IO (FunPtr CReadLink)

type CMkNod = CString -> CMode -> CDev -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkMkNod :: CMkNod -> IO (FunPtr CMkNod)

type CMkDir = CString -> CMode -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkMkDir :: CMkDir -> IO (FunPtr CMkDir)

type CUnlink = CString -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkUnlink :: CUnlink -> IO (FunPtr CUnlink)

type CRmDir = CString -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkRmDir :: CRmDir -> IO (FunPtr CRmDir)

type CSymLink = CString -> CString -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkSymLink :: CSymLink -> IO (FunPtr CSymLink)

type CRename = CString -> CString -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkRename :: CRename -> IO (FunPtr CRename)

type CLink = CString -> CString -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkLink :: CLink -> IO (FunPtr CLink)

type CChMod = CString -> CMode -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkChMod :: CChMod -> IO (FunPtr CChMod)

type CChOwn = CString -> CUid -> CGid -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkChOwn :: CChOwn -> IO (FunPtr CChOwn)

type CTruncate = CString -> COff -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkTruncate :: CTruncate -> IO (FunPtr CTruncate)

data CUTimBuf -- struct utimbuf
type CUTime = CString -> Ptr CUTimBuf -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkUTime :: CUTime -> IO (FunPtr CUTime)

type COpen = CString -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkOpen :: COpen -> IO (FunPtr COpen)

type CRead = CString -> CString -> CSize -> COff -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkRead :: CRead -> IO (FunPtr CRead)

type CWrite = CString -> CString -> CSize -> COff -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkWrite :: CWrite -> IO (FunPtr CWrite)

data CStructStatFS -- struct fuse_stat_fs
type CStatFS = CString -> Ptr CStructStatFS -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkStatFS :: CStatFS -> IO (FunPtr CStatFS)

type CFlush = CString -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkFlush :: CFlush -> IO (FunPtr CFlush)

type CRelease = CString -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkRelease :: CRelease -> IO (FunPtr CRelease)

type CFSync = CString -> Int -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkFSync :: CFSync -> IO (FunPtr CFSync) 

-- XXX add *xattr bindings

type COpenDir = CString -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkOpenDir :: COpenDir -> IO (FunPtr COpenDir)

type CReadDir = CString -> Ptr CFillDirBuf -> FunPtr CFillDir -> COff
             -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkReadDir :: CReadDir -> IO (FunPtr CReadDir)

type CReleaseDir = CString -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkReleaseDir :: CReleaseDir -> IO (FunPtr CReleaseDir)

type CFSyncDir = CString -> Int -> Ptr CFuseFileInfo -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkFSyncDir :: CFSyncDir -> IO (FunPtr CFSyncDir)

type CAccess = CString -> CInt -> IO CInt
foreign import ccall threadsafe "wrapper"
    mkAccess :: CAccess -> IO (FunPtr CAccess)

-- CInt because anything would be fine as we don't use them
type CInit = Ptr CFuseConnInfo -> IO (Ptr CInt)
foreign import ccall threadsafe "wrapper"
    mkInit :: CInit -> IO (FunPtr CInit)

type CDestroy = Ptr CInt -> IO ()
foreign import ccall threadsafe "wrapper"
    mkDestroy :: CDestroy -> IO (FunPtr CDestroy)

----

bsToBuf :: Ptr a -> B.ByteString -> Int -> IO ()
bsToBuf dst bs len = do
  let l = fromIntegral $ min len $ B.length bs
  B.unsafeUseAsCString bs $ \src -> B.memcpy (castPtr dst) (castPtr src) l
  return ()

-- Get filehandle
getFH pFuseFileInfo = do
  sptr <- (#peek struct fuse_file_info, fh) pFuseFileInfo
  cVal <- deRefStablePtr $ castPtrToStablePtr sptr
  return cVal

delFH pFuseFileInfo = do
  sptr <- (#peek struct fuse_file_info, fh) pFuseFileInfo
  freeStablePtr $ castPtrToStablePtr sptr


---
-- dynamic C called from Haskell
---

data CDirHandle -- fuse_dirh_t
type CDirFil = Ptr CDirHandle -> CString -> Int -> IO CInt -- fuse_dirfil_t
foreign import ccall threadsafe "dynamic"
    mkDirFil :: FunPtr CDirFil -> CDirFil

data CFillDirBuf -- void
type CFillDir = Ptr CFillDirBuf -> CString -> Ptr CStat -> COff -> IO CInt
foreign import ccall threadsafe "dynamic"
    mkFillDir :: FunPtr CFillDir -> CFillDir