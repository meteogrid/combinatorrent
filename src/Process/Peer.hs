-- | Peer proceeses
{-# LANGUAGE ScopedTypeVariables #-}
module Process.Peer (
    -- * Types
      PeerMessage(..)
    -- * Interface
    , Process.Peer.start
    )
where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.CML.Strict
import Control.Concurrent.STM

import Control.Monad.State
import Control.Monad.Reader

import Prelude hiding (catch, log)

import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L

import qualified Data.Map as M
import qualified Data.PieceSet as PS
import Data.Maybe

import Data.Set as S hiding (map)
import Data.Time.Clock
import Data.Word

import System.IO

import PeerTypes
import Process
import Process.FS
import Process.PieceMgr
import RateCalc as RC
import Process.Status
import Process.ChokeMgr (RateTVar)
import Supervisor
import Process.Timer as Timer
import Torrent
import Protocol.Wire

import qualified Process.Peer.Sender as Sender
import qualified Process.Peer.SenderQ as SenderQ
import qualified Process.Peer.Receiver as Receiver

-- INTERFACE
----------------------------------------------------------------------

start :: Handle -> MgrChannel -> RateTVar -> PieceMgrChannel
             -> FSPChannel -> TVar [PStat] -> PieceMap -> Int -> InfoHash
             -> IO Children
start handle pMgrC rtv pieceMgrC fsC stv pm nPieces ih = do
    queueC <- channel
    senderC <- channel
    receiverC <- channel
    sendBWC <- channel
    return [Worker $ Sender.start handle senderC,
            Worker $ SenderQ.start queueC senderC sendBWC,
            Worker $ Receiver.start handle receiverC,
            Worker $ peerP pMgrC rtv pieceMgrC fsC pm nPieces
                                queueC receiverC sendBWC stv ih]

-- INTERNAL FUNCTIONS
----------------------------------------------------------------------

data PCF = PCF { inCh :: Channel (Message, Integer)
               , outCh :: Channel SenderQ.SenderQMsg
               , peerMgrCh :: MgrChannel
               , pieceMgrCh :: PieceMgrChannel
               , fsCh :: FSPChannel
               , peerCh :: PeerChannel
               , sendBWCh :: BandwidthChannel
               , timerCh :: Channel ()
               , statTV :: TVar [PStat]
               , rateTV :: RateTVar
               , pcInfoHash :: InfoHash
               , pieceMap :: PieceMap
               }

instance Logging PCF where
    logName _ = "Process.Peer"

data PST = PST { weChoke :: Bool -- ^ True if we are choking the peer
               , weInterested :: Bool -- ^ True if we are interested in the peer
               , blockQueue :: S.Set (PieceNum, Block) -- ^ Blocks queued at the peer
               , peerChoke :: Bool -- ^ Is the peer choking us? True if yes
               , peerInterested :: Bool -- ^ True if the peer is interested
               , peerPieces :: PS.PieceSet -- ^ List of pieces the peer has access to
               , upRate :: Rate -- ^ Upload rate towards the peer (estimated)
               , downRate :: Rate -- ^ Download rate from the peer (estimated)
               , runningEndgame :: Bool -- ^ True if we are in endgame
               }

peerP :: MgrChannel -> RateTVar -> PieceMgrChannel -> FSPChannel -> PieceMap -> Int
         -> Channel SenderQ.SenderQMsg -> Channel (Message, Integer) -> BandwidthChannel
         -> TVar [PStat] -> InfoHash
         -> SupervisorChan -> IO ThreadId
peerP pMgrC rtv pieceMgrC fsC pm nPieces outBound inBound sendBWC stv ih supC = do
    ch <- channel
    tch <- channel
    ct <- getCurrentTime
    pieceSet <- PS.new nPieces
    spawnP (PCF inBound outBound pMgrC pieceMgrC fsC ch sendBWC tch stv rtv ih pm)
           (PST True False S.empty True False pieceSet (RC.new ct) (RC.new ct) False)
           (cleanupP startup (defaultStopHandler supC) cleanup)
  where startup = do
            tid <- liftIO $ myThreadId
            debugP "Syncing a connectBack"
            asks peerCh >>= (\ch -> sendPC peerMgrCh $ Connect ih tid ch) >>= syncP
            pieces <- getPiecesDone
            syncP =<< (sendPC outCh $ SenderQ.SenderQM $ BitField (constructBitField nPieces pieces))
            -- Install the StatusP timer
            c <- asks timerCh
            Timer.register 5 () c
            foreverP (eventLoop tid)

        cleanup = do
            t <- liftIO myThreadId
            pieces <- gets peerPieces >>= PS.toList
            ch <- asks pieceMgrCh
            liftIO . atomically $ writeTChan ch (PeerUnhave pieces)
            syncP =<< sendPC peerMgrCh (Disconnect t)

        eventLoop tid = {-# SCC "Peer.Control" #-} do
            syncP =<< chooseP [peerMsgEvent, chokeMgrEvent, upRateEvent, timerEvent tid]

-- | Return a list of pieces which are currently done by us
getPiecesDone :: Process PCF PST [PieceNum]
getPiecesDone = do
    ch <- asks pieceMgrCh
    liftIO $ do
      c <- newEmptyTMVarIO
      atomically $ writeTChan ch (GetDone c)
      atomically $ readTMVar c

-- | Process an event from the Choke Manager
chokeMgrEvent :: Process PCF PST (Event ((), PST))
chokeMgrEvent = do
    evt <- recvPC peerCh
    wrapP evt (\msg -> do
        debugP "ChokeMgrEvent"
        case msg of
            PieceCompleted pn -> do
                syncP =<< (sendPC outCh $ SenderQ.SenderQM $ Have pn)
            ChokePeer -> do choking <- gets weChoke
                            when (not choking)
                                 (do syncP =<< sendPC outCh SenderQ.SenderOChoke
                                     debugP "ChokePeer"
                                     modify (\s -> s {weChoke = True}))
            UnchokePeer -> do choking <- gets weChoke
                              when choking
                                   (do syncP =<< (sendPC outCh $ SenderQ.SenderQM Unchoke)
                                       debugP "UnchokePeer"
                                       modify (\s -> s {weChoke = False}))
            CancelBlock pn blk -> do
                modify (\s -> s { blockQueue = S.delete (pn, blk) $ blockQueue s })
                syncP =<< (sendPC outCh $ SenderQ.SenderQRequestPrune pn blk))

-- True if the peer is a seeder
-- Optimization: Don't calculate this all the time. It only changes once and then it keeps
--   being there.
isASeeder :: Process PCF PST Bool
isASeeder = liftM2 (==) (gets peerPieces >>= PS.size) (M.size <$> asks pieceMap)

-- A Timer event handles a number of different status updates. One towards the
-- Choke Manager so it has a information about whom to choke and unchoke - and
-- one towards the status process to keep track of uploaded and downloaded
-- stuff.
timerEvent :: ThreadId -> Process PCF PST (Event ((), PST))
timerEvent mTid = do
    evt <- recvPC timerCh
    wrapP evt (\() -> do
        debugP "TimerEvent"
        tch <- asks timerCh
        Timer.register 5 () tch
        -- Tell the ChokeMgr about our progress
        ur <- gets upRate
        dr <- gets downRate
        t <- liftIO $ getCurrentTime
        let (up, nur) = RC.extractRate t ur
            (down, ndr) = RC.extractRate t dr
        infoP $ "Peer has rates up/down: " ++ show up ++ "/" ++ show down
        i <- gets peerInterested
        seed <- isASeeder
        pchoke <- gets peerChoke
        rtv <- asks rateTV
        liftIO . atomically $ do
            q <- readTVar rtv
            writeTVar rtv ((mTid, (up, down, i, seed, pchoke)) : q)
        -- Tell the Status Process about our progress
        let (upCnt, nuRate) = RC.extractCount $ nur
            (downCnt, ndRate) = RC.extractCount $ ndr
        debugP $ "Sending peerStats: " ++ show upCnt ++ ", " ++ show downCnt
        stv <- asks statTV
        ih <- asks pcInfoHash
        liftIO .atomically $ do
            q <- readTVar stv
            writeTVar stv (PStat { pInfoHash = ih
                                 , pUploaded = upCnt
                                 , pDownloaded = downCnt } : q)
        modify (\s -> s { upRate = nuRate, downRate = ndRate }))

-- | Process an event from the send queue with new information about the upload
-- rate
upRateEvent :: Process PCF PST (Event ((), PST))
upRateEvent = do
    evt <- recvPC sendBWCh
    wrapP evt (\uploaded -> do
        modify (\s -> s { upRate = RC.update uploaded $ upRate s}))

-- | Process an Message from the peer in the other end of the socket.
peerMsgEvent :: Process PCF PST (Event ((), PST))
peerMsgEvent = do
    evt <- recvPC inCh
    wrapP evt (\(msg, sz) -> do
        modify (\s -> s { downRate = RC.update sz $ downRate s})
        case msg of
          KeepAlive  -> return ()
          Choke      -> do putbackBlocks
                           modify (\s -> s { peerChoke = True })
          Unchoke    -> do modify (\s -> s { peerChoke = False })
                           fillBlocks
          Interested -> modify (\s -> s { peerInterested = True })
          NotInterested -> modify (\s -> s { peerInterested = False })
          Have pn -> haveMsg pn
          BitField bf -> bitfieldMsg bf
          Request pn blk -> requestMsg pn blk
          Piece n os bs -> do pieceMsg n os bs
                              fillBlocks
          Cancel pn blk -> cancelMsg pn blk
          Port _ -> return ()) -- No DHT yet, silently ignore

-- | Put back blocks for other peer processes to grab. This is done whenever
-- the peer chokes us, or if we die by an unknown cause.
putbackBlocks :: Process PCF PST ()
putbackBlocks = do
    blks <- gets blockQueue
    pmch <- asks pieceMgrCh
    liftIO . atomically $ writeTChan pmch (PutbackBlocks (S.toList blks))
    modify (\s -> s { blockQueue = S.empty })

-- | Process a HAVE message from the peer. Note we also update interest as a side effect
haveMsg :: PieceNum -> Process PCF PST ()
haveMsg pn = do
    pm <- asks pieceMap
    if M.member pn pm
        then do PS.insert pn =<< gets peerPieces
                pmch <- asks pieceMgrCh
                liftIO . atomically $ writeTChan pmch (PeerHave [pn])
                considerInterest
        else do warningP "Unknown Piece"
                stopP

-- | Process a BITFIELD message from the peer. Side effect: Consider Interest.
bitfieldMsg :: BitField -> Process PCF PST ()
bitfieldMsg bf = do
    pieces <- gets peerPieces
    piecesNull <- PS.null pieces
    if piecesNull
        -- TODO: Don't trust the bitfield
        then do nPieces <- M.size <$> asks pieceMap
                peerP <- createPeerPieces nPieces bf
                modify (\s -> s { peerPieces = peerP })
                peerLs <- PS.toList peerP
                pmch <- asks pieceMgrCh
                liftIO . atomically $ writeTChan pmch (PeerHave peerLs)
                considerInterest
        else do infoP "Got out of band Bitfield request, dying"
                stopP

-- | Process a request message from the Peer
requestMsg :: PieceNum -> Block -> Process PCF PST ()
requestMsg pn blk = do
    choking <- gets weChoke
    unless (choking)
         (do
            bs <- readBlock pn blk -- TODO: Pushdown to send process
            syncP =<< sendPC outCh (SenderQ.SenderQM $ Piece pn (blockOffset blk) bs))

-- | Read a block from the filesystem for sending
readBlock :: PieceNum -> Block -> Process PCF PST B.ByteString
readBlock pn blk = do
    c <- liftIO $ channel
    syncP =<< sendPC fsCh (ReadBlock pn blk c)
    syncP =<< recvP c (const True)

-- | Handle a Piece Message incoming from the peer
pieceMsg :: PieceNum -> Int -> B.ByteString -> Process PCF PST ()
pieceMsg n os bs = do
    let sz = B.length bs
        blk = Block os sz
        e = (n, blk)
    q <- gets blockQueue
    -- When e is not a member, the piece may be stray, so ignore it.
    -- Perhaps print something here.
    when (S.member e q)
        (do storeBlock n (Block os sz) bs
            modify (\s -> s { blockQueue = S.delete e (blockQueue s)}))

-- | Handle a cancel message from the peer
cancelMsg :: PieceNum -> Block -> Process PCF PST ()
cancelMsg n blk =
    syncP =<< sendPC outCh (SenderQ.SenderQCancel n blk)

-- | Update our interest state based on the pieces the peer has.
--   Obvious optimization: Do less work, there is no need to consider all pieces most of the time
considerInterest :: Process PCF PST ()
considerInterest = do
    c <- liftIO newEmptyTMVarIO
    pcs <- gets peerPieces
    pmch <- asks pieceMgrCh
    interested <- liftIO $ do
        atomically $ writeTChan pmch (AskInterested pcs c)
        atomically $ readTMVar c
    if interested
        then do modify (\s -> s { weInterested = True })
                syncP =<< sendPC outCh (SenderQ.SenderQM Interested)
        else modify (\s -> s { weInterested = False})

-- | Try to fill up the block queue at the peer. The reason we pipeline a
-- number of blocks is to get around the line delay present on the internet.
fillBlocks :: Process PCF PST ()
fillBlocks = do
    choked <- gets peerChoke
    unless choked checkWatermark

-- | check the current Watermark level. If we are below the lower one, then
-- fill till the upper one. This in turn keeps the pipeline of pieces full as
-- long as the peer is interested in talking to us.
-- TODO: Decide on a queue size based on the current download rate.
checkWatermark :: Process PCF PST ()
checkWatermark = do
    q <- gets blockQueue
    eg <- gets runningEndgame
    let sz = S.size q
        mark = if eg then endgameLoMark else loMark
    when (sz < mark)
        (do
           toQueue <- grabBlocks (hiMark - sz)
           debugP $ "Got " ++ show (length toQueue) ++ " blocks: " ++ show toQueue
           queuePieces toQueue)

-- These three values are chosen rather arbitrarily at the moment.
loMark :: Int
loMark = 10

hiMark :: Int
hiMark = 15

-- Low mark when running in endgame mode
endgameLoMark :: Int
endgameLoMark = 1


-- | Queue up pieces for retrieval at the Peer
queuePieces :: [(PieceNum, Block)] -> Process PCF PST ()
queuePieces toQueue = do
    mapM_ (uncurry pushRequest) toQueue
    modify (\s -> s { blockQueue = S.union (blockQueue s) (S.fromList toQueue) })

-- | Push a request to the peer so he can send it to us
pushRequest :: PieceNum -> Block -> Process PCF PST ()
pushRequest pn blk =
    syncP =<< sendPC outCh (SenderQ.SenderQM $ Request pn blk)

-- | Tell the PieceManager to store the given block
storeBlock :: PieceNum -> Block -> B.ByteString -> Process PCF PST ()
storeBlock n blk bs = do
    pmch <- asks pieceMgrCh
    liftIO . atomically $ writeTChan pmch (StoreBlock n blk bs)

-- | The call @grabBlocks n@ will attempt to grab (up to) @n@ blocks from the
-- piece Manager for request at the peer.
grabBlocks :: Int -> Process PCF PST [(PieceNum, Block)]
grabBlocks n = do
    c <- liftIO newEmptyTMVarIO
    ps <- gets peerPieces
    pmch <- asks pieceMgrCh
    blks <- liftIO $ do
        atomically $ writeTChan pmch (GrabBlocks n ps c)
        atomically $ readTMVar c
    case blks of
        Leech blks -> return blks
        Endgame blks ->
            modify (\s -> s { runningEndgame = True }) >> return blks


createPeerPieces :: MonadIO m => Int -> L.ByteString -> m PS.PieceSet
createPeerPieces nPieces =
    PS.fromList nPieces . map fromIntegral . concat . decodeBytes 0 . L.unpack
  where decodeByte :: Int -> Word8 -> [Maybe Int]
        decodeByte soFar w =
            let dBit n = if testBit w (7-n)
                           then Just (n+soFar)
                           else Nothing
            in fmap dBit [0..7]
        decodeBytes _ [] = []
        decodeBytes soFar (w : ws) = catMaybes (decodeByte soFar w) : decodeBytes (soFar + 8) ws
