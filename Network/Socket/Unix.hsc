#include "HsNet.h"
##include "HsNetDef.h"

module Network.Socket.Unix (
    isUnixDomainSocketAvailable
  , socketPair
  , sendFd
  , recvFd
  , getPeerCredential
  , getPeerCred
  , getPeerEid
  ) where

import Network.Socket.Imports
import Network.Socket.Types

#ifdef HAVE_STRUCT_UCRED_SO_PEERCRED
import Foreign.Marshal.Utils (with)
#endif
#ifdef HAVE_GETPEEREID
import qualified Control.Exception as E
import Foreign.Marshal.Alloc (alloca)
#endif
#ifdef DOMAIN_SOCKET_SUPPORT
import Control.Monad (void)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (peekArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable(..))

import Network.Socket.Fcntl
import Network.Socket.Internal
#endif
#ifdef HAVE_STRUCT_UCRED_SO_PEERCRED
import Network.Socket.Options (c_getsockopt)
#endif

-- | Getting process ID, user ID and group ID for Unix domain sockets.
--
--   Since 3.0.0.0.
getPeerCredential :: Socket -> IO (Maybe CUInt, Maybe CUInt, Maybe CUInt)
#ifdef HAVE_STRUCT_UCRED_SO_PEERCRED
getPeerCredential sock = do
    (pid, uid, gid) <- getPeerCred sock
    if uid == maxBound then
        return (Nothing, Nothing, Nothing)
      else
        return (Just pid, Just uid, Just gid)
#elif defined(HAVE_GETPEEREID)
getPeerCredential sock = E.handle (\(E.SomeException _) -> return (Nothing,Nothing,Nothing)) $ do
    (uid, gid) <- getPeerEid sock
    return (Nothing, Just uid, Just gid)
#else
getPeerCredential _ = return (Nothing, Nothing, Nothing)
#endif

-- | Returns the processID, userID and groupID of the peer of
--   a UNIX domain socket.
--
-- Only available on platforms that support SO_PEERCRED.
getPeerCred :: Socket -> IO (CUInt, CUInt, CUInt)
#ifdef HAVE_STRUCT_UCRED_SO_PEERCRED
getPeerCred s = do
  let sz = (#const sizeof(struct ucred))
      fd = fdSocket s
  allocaBytes sz $ \ ptr_cr ->
   with (fromIntegral sz) $ \ ptr_sz -> do
     _ <- ($) throwSocketErrorIfMinus1Retry "Network.Socket.getPeerCred" $
       c_getsockopt fd (#const SOL_SOCKET) (#const SO_PEERCRED) ptr_cr ptr_sz
     pid <- (#peek struct ucred, pid) ptr_cr
     uid <- (#peek struct ucred, uid) ptr_cr
     gid <- (#peek struct ucred, gid) ptr_cr
     return (pid, uid, gid)
#else
getPeerCred _ = return (0, 0, 0)
#endif
{-# Deprecated getPeerCred "Use getPeerCredential instead" #-}

-- | Returns the userID and groupID of the peer of
--   a UNIX domain socket.
--
--  Only available on platforms that support getpeereid().
getPeerEid :: Socket -> IO (CUInt, CUInt)
#ifdef HAVE_GETPEEREID
getPeerEid s = do
  alloca $ \ ptr_uid ->
    alloca $ \ ptr_gid -> do
      throwSocketErrorIfMinus1Retry_ "Network.Socket.getPeerEid" $
        c_getpeereid (fdSocket s) ptr_uid ptr_gid
      uid <- peek ptr_uid
      gid <- peek ptr_gid
      return (uid, gid)

foreign import CALLCONV unsafe "getpeereid"
  c_getpeereid :: CInt -> Ptr CUInt -> Ptr CUInt -> IO CInt
#else
getPeerEid _ = return (0, 0)
#endif

{-# Deprecated getPeerEid "Use getPeerCredential instead" #-}

-- | Whether or not Unix domain sockets are available.
--
--   Since 3.0.0.0.
isUnixDomainSocketAvailable :: Bool
#if defined(DOMAIN_SOCKET_SUPPORT)
isUnixDomainSocketAvailable = True
#else
isUnixDomainSocketAvailable = False
#endif

-- | Send a file descriptor over a Unix domain socket.
--   Use this function in the case where 'isUnixDomainSocketAvailable' is
--  'True'.
sendFd :: Socket -> CInt -> IO ()
#if defined(DOMAIN_SOCKET_SUPPORT)
sendFd s outfd = void $
  throwSocketErrorWaitWrite s "Network.Socket.sendFd" $ c_sendFd (fdSocket s) outfd
foreign import ccall SAFE_ON_WIN "sendFd" c_sendFd :: CInt -> CInt -> IO CInt
#else
sendFd _ _ = error "Network.Socket.sendFd"
#endif

-- | Receive a file descriptor over a Unix domain socket. Note that the resulting
--   file descriptor may have to be put into non-blocking mode in order to be
--   used safely. See 'setNonBlockIfNeeded'.
--   Use this function in the case where 'isUnixDomainSocketAvailable' is
--  'True'.
recvFd :: Socket -> IO CInt
#if defined(DOMAIN_SOCKET_SUPPORT)
recvFd s =
  throwSocketErrorWaitRead s "Network.Socket.recvFd" $ c_recvFd (fdSocket s)
foreign import ccall SAFE_ON_WIN "recvFd" c_recvFd :: CInt -> IO CInt
#else
recvFd _ = error "Network.Socket.recvFd"
#endif

-- | Build a pair of connected socket objects.
--   For portability, use this function in the case
--   where 'isUnixDomainSocketAvailable' is 'True'
--   and specify 'AF_UNIX' to the first argument.
socketPair :: Family              -- Family Name (usually AF_UNIX)
           -> SocketType          -- Socket Type (usually Stream)
           -> ProtocolNumber      -- Protocol Number
           -> IO (Socket, Socket) -- unnamed and connected.
#if defined(DOMAIN_SOCKET_SUPPORT)
socketPair family stype protocol =
    allocaBytes (2 * sizeOf (1 :: CInt)) $ \ fdArr -> do
      c_stype <- packSocketTypeOrThrow "socketPair" stype
      _rc <- throwSocketErrorIfMinus1Retry "Network.Socket.socketpair" $
                  c_socketpair (packFamily family) c_stype protocol fdArr
      [fd1,fd2] <- peekArray 2 fdArr
      setNonBlockIfNeeded fd1
      setNonBlockIfNeeded fd2
      let s1 = mkSocket fd1
          s2 = mkSocket fd2
      return (s1, s2)

foreign import ccall unsafe "socketpair"
  c_socketpair :: CInt -> CInt -> CInt -> Ptr CInt -> IO CInt
#else
socketPair _ _ _ = error "Network.Socket.socketPair"
#endif
