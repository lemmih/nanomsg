{-# LANGUAGE ForeignFunctionInterface #-}
#include <nanomsg/nn.h>
#include <nanomsg/pipeline.h>
#include <nanomsg/pair.h>
#include <nanomsg/pubsub.h>
#include <nanomsg/reqrep.h>
-- | nanomsg - scalability protocols library
module System.Nanomsg
  ( -- * Types
    Domain(..)
  , Protocol(..)
  , EID
  , Socket
    -- * API
  , socket
  , close
  , bind
  , connect
  , shutdown
  , send
  , recv
  , freemsg
  ) where

import           Data.ByteString          (ByteString)
import           Data.ByteString.Unsafe   (unsafeUseAsCString, unsafePackCStringLen)
import qualified Data.ByteString as B
import           Foreign                  (Ptr, alloca, with, peek, sizeOf)
import           Foreign.C
import           Control.Monad            (void)
import           Data.Function            (fix)
import           System.Posix.Types       (Fd(..))
import           Control.Concurrent       (threadWaitRead, threadWaitWrite)

type Socket = CInt

nn_msg :: CSize
nn_msg = #const NN_MSG

nn_dontwait :: CInt
nn_dontwait = #const NN_DONTWAIT

nn_sol_socket :: CInt
nn_sol_socket = #const NN_SOL_SOCKET

nn_rcvfd :: CInt
nn_rcvfd = #const NN_RCVFD

nn_sndfd :: CInt
nn_sndfd = #const NN_SNDFD

-- | End-point ID
type EID = CInt

data Domain
  = AF_SP     -- ^ Standard full-blown SP socket.
  | AF_SP_RAW -- ^ Raw SP socket. Raw sockets omit the end-to-end functionality
              --   found in AF_SP sockets and thus can be used to implement
              --   intermediary devices in SP topologies.

data Protocol
  = Pair -- ^ One-to-one protocol. Socket for communication with exactly
         --   one peer. Each party can send messages at any time. If the
         --   peer is not available or send buffer is full subsequent calls
         --   to 'send' will block until it’s possible to send the message.
  | Pub  -- ^ Publish/subscribe protocol. This socket is used to distribute
         --   messages to multiple destinations. Receive operation is not
         --   defined.
  | Sub  -- ^ Publish/subscribe protocol. Receives messages from the publisher.
         --   Only messages that the socket is subscribed to are received.
         --   When the socket is created there are no subscriptions and thus
         --   no messages will be received. Send operation is not defined on
         --   this socket.
  | Rep  -- ^ Request/reply protocol. Used to implement the stateless worker
         --   that receives requests and sends replies.
  | Req  -- ^ Request/reply protocol. Used to implement the client application
         --   that sends requests and receives replies.
  | Push -- ^ Pipeline protocol. This socket is used to send messages to a
         --   cluster of load-balanced nodes. Receive operation is not
         --   implemented on this socket type.
  | Pull -- ^ Pipeline protocol. This socket is used to receive a message from
         --   a cluster of nodes. Send operation is not implemented on this
         --   socket type.

domainToCInt :: Domain -> CInt
domainToCInt AF_SP     = #const AF_SP
domainToCInt AF_SP_RAW = #const AF_SP_RAW

protocolToCInt :: Protocol -> CInt
protocolToCInt Pair = #const NN_PAIR
protocolToCInt Pub  = #const NN_PUB
protocolToCInt Sub  = #const NN_SUB
protocolToCInt Rep  = #const NN_REP
protocolToCInt Req  = #const NN_REQ
protocolToCInt Push = #const NN_PUSH
protocolToCInt Pull = #const NN_PULL

-- int nn_socket (int domain, int protocol);
foreign import ccall unsafe "nn_socket" nn_socket :: CInt -> CInt -> IO CInt

-- | Creates an SP socket with specified domain and protocol.
--
--   The newly created socket is initially not associated with any endpoints.
--   In order to establish a message flow at least one endpoint has to be added
--   to the socket using 'bind' or 'connect' function.
socket :: Domain -> Protocol -> IO Socket
socket domain protocol = throwErrnoIfMinus1 "nn_socket" $
  nn_socket (domainToCInt domain) (protocolToCInt protocol)

-- int nn_close (int s);
foreign import ccall unsafe "nn_close" nn_close :: CInt -> IO CInt

-- | Closes the socket. Any buffered inbound messages that were not yet
--   received by the application will be discarded. The library will try to
--   deliver any outstanding outbound messages for the time specified by
--   NN_LINGER socket option. The call will block in the meantime.
close :: Socket -> IO ()
close socket = void $ throwErrnoIfMinus1 "nn_close" $ nn_close socket

-- int nn_bind (int s, const char *addr);
foreign import ccall unsafe "nn_bind" nn_bind :: CInt -> CString -> IO CInt

-- | Adds a local endpoint to the socket. The endpoint can be then used by
--   other applications to connect to.
--
--   The addr argument consists of two parts as follows: transport://address.
--   The transport specifies the underlying transport protocol to use. The
--   meaning of the address part is specific to the underlying transport
--   protocol.
--
--   For the list of available transport protocols check the list on nanomsg(7)
--   manual page.
--
--   Maximum length of the addr parameter is specified by NN_SOCKADDR_MAX
--   defined in '<nanomsg/nn.h>' header file.
--
--   Note that 'bind' and 'connect' may be called multiple times on the
--   same socket thus allowing the socket to communicate with multiple
--   heterogeneous endpoints.
bind :: Socket -> String -> IO EID
bind socket url =
  withCString url $ \cstr ->
    throwErrnoIfMinus1 "nn_bind" $ nn_bind socket cstr

-- int nn_connect (int s, const char *addr);
foreign import ccall unsafe nn_connect :: CInt -> CString -> IO CInt

-- | Adds a remote endpoint to the socket. The library would then try to
--   connect to the specified remote endpoint.

--   The addr argument consists of two parts as follows: transport://address.
--   The transport specifies the underlying transport protocol to use. The
--   meaning of the address part is specific to the underlying transport
--   protocol.
--
--   For the list of available transport protocols check the list on nanomsg(7)
--   manual page.
--
--   Maximum length of the addr parameter is specified by NN_SOCKADDR_MAX
--   defined in <nanomsg/nn.h> header file.
--
--   Note that 'connect' and 'bind' may be called multiple times on the
--   same socket thus allowing the socket to communicate with multiple
--   heterogeneous endpoints.
connect :: Socket -> String -> IO EID
connect socket url =
  withCString url $ \cstr ->
    throwErrnoIfMinus1 "nn_connect" $ nn_connect socket cstr

-- int nn_shutdown (int s, int how);
foreign import ccall unsafe nn_shutdown :: CInt -> CInt -> IO CInt

-- | Removes an endpoint from socket. The second parameter specifies the ID of
--   the endpoint to remove as returned by prior call to 'bind' or 'connect'.
--   'shutdown' call will return immediately, however, the library will try to
--   deliver any outstanding outbound messages to the endpoint for the time
--   specified by NN_LINGER socket option.
shutdown :: Socket -> EID -> IO ()
shutdown socket eid = void $ throwErrnoIfMinus1 "nn_shutdown" $ nn_shutdown socket eid

-- int nn_recv (int s, void *buf, size_t len, int flags);
foreign import ccall unsafe nn_recv :: CInt -> Ptr a -> CSize -> CInt -> IO CInt

-- | Receive incoming message as a strict bytestring using zero-copy
--   techniques. The bytestring must be deallocated using 'freemsg'.
recv :: Socket -> IO ByteString
recv socket =
  alloca $ \bufPtr -> do
    ret <- fix $ \loop -> do
      fd <- getRcvFd socket
      threadWaitRead fd
      val <- nn_recv socket bufPtr nn_msg nn_dontwait
      if val >= 0
        then return val
        else do
          errno <- getErrno
          if errno == eAGAIN
            then loop
            else throwErrno "nn_recv"
    buf <- peek bufPtr
    unsafePackCStringLen (buf, fromIntegral ret)

-- int nn_send (int s, const void *buf, size_t len, int flags);
foreign import ccall unsafe nn_send :: CInt -> Ptr a -> CSize -> CInt -> IO CInt

-- | The function will send a message containing the data from a strict
--   bytestring to a socket.
--
--   Which of the peers the message will be sent to is determined by the
--   particular socket type.
send :: Socket -> ByteString -> IO ()
send socket bs =
  unsafeUseAsCString bs $ \buf ->
  fix $ \loop -> do
    fd <- getSndFd socket
    threadWaitWrite fd
    val <- nn_send socket buf (fromIntegral $ B.length bs) 0
    if val >= 0
      then return ()
      else do
        errno <- getErrno
        if errno == eAGAIN
          then loop
          else throwErrno "nn_send"

-- int nn_freemsg (void *msg);
foreign import ccall unsafe nn_freemsg :: Ptr a -> IO CInt

-- | Deallocates a message allocated using 'allocmsg' function or received
--   via 'recv' function.
freemsg :: ByteString -> IO ()
freemsg msg =
  unsafeUseAsCString msg $ \cstr -> do
    ret <- nn_freemsg cstr
    -- FIXME: Check for errors
    return ()

-- int nn_getsockopt (int s, int level, int option, void *optval, size_t *optvallen);
foreign import ccall unsafe nn_getsockopt :: CInt -> CInt -> CInt -> Ptr a -> Ptr CSize -> IO CInt

getRcvFd :: Socket -> IO Fd
getRcvFd socket =
  alloca $ \fdPtr ->
  with (fromIntegral $ sizeOf (undefined ::CInt)) $ \sizePtr -> do
    throwErrnoIfMinus1 "nn_getsockopt" $
      nn_getsockopt socket nn_sol_socket nn_rcvfd fdPtr sizePtr
    fd <- peek fdPtr
    return $ Fd fd

getSndFd :: Socket -> IO Fd
getSndFd socket =
  alloca $ \fdPtr ->
  with (fromIntegral $ sizeOf (undefined ::CInt)) $ \sizePtr -> do
    throwErrnoIfMinus1 "nn_getsockopt" $
      nn_getsockopt socket nn_sol_socket nn_sndfd fdPtr sizePtr
    fd <- peek fdPtr
    return $ Fd fd








