{-# LANGUAGE Strict #-}

module Control.Concurrent.ThreadPool where

import           Control.Monad
import           Data.Default
import           Data.Functor
import           UnliftIO
import           UnliftIO.Concurrent

import           Control.Concurrent.Supervisor

{-|
    `PoolMessage` defines all messages for pool manager actor.
    It follows Server behavior rule from thread-supervisor package.
-}
data PoolMessage
    = Down ExitReason                                       -- ^ Notification on thread termination.
    | Run (IO ()) (ServerCallback (Maybe ThreadId))         -- ^ Request to run a thread.  Returns `ThreadId` on success, `Nothing` on supervisor timeout or pool is full.
    | RunSync (IO ()) (ServerCallback (Maybe ThreadId))     -- ^ Request to run a thread.  Waits for available resource.  Returns `ThreadId` on success, `Nothing` on timeout.

-- | Type synonym of pool manager actor's write-end queue.
type PoolQueue = ActorQ PoolMessage

-- | Create an actor of thread pool
newThreadPool
    :: Int                              -- ^ Maximum number of threads runnable at a time.
    -> IO (Actor PoolMessage ())
newThreadPool maxThreads = do
    Actor workerSvQ workerSv <- newActor newSimpleOneForOneSupervisor       -- Supervisor for worker threads.
    Actor poolManQ poolMan <- newActor $ poolManager workerSvQ maxThreads   -- Actor managing pool.
    Actor _ topSv <- newActor $ newSupervisor OneForAll def                 -- Top level actor.
        [ newChildSpec Permanent workerSv
        , newChildSpec Permanent poolMan]
    pure $ Actor poolManQ topSv

poolManager :: SupervisorQueue -> Int -> ActorHandler PoolMessage ()
poolManager workerSvQ maxThreads inbox = do
    cleanupQueue
    go maxThreads
  where
    cleanupQueue = tryReceiveSelect isDown inbox >>= go
      where
        go Nothing  = pure ()
        go (Just _) = tryReceiveSelect isDown inbox >>= go

        isDown (Down _) = True
        isDown _        = False

    go avail = do
        message <- receiveSelect (dontReceiveQueueOnNoResource avail) inbox
        go =<< case message of
            (Down _)                            -> pure $ avail + 1
            (Run action cont)   | avail <= 0    -> cont Nothing $> avail
                                | otherwise     -> (startThread action >>= cont) $> avail - 1
            (RunSync action cont)               -> (startThread action >>= cont) $> avail - 1

    dontReceiveQueueOnNoResource avail (RunSync _ _)    | avail <= 0    = False
                                                        | otherwise     = True
    dontReceiveQueueOnNoResource _ _                                    = True

    startThread action = do
        let spec = newMonitoredChildSpec Temporary $ watch (\reason _ -> send (ActorQ inbox) $ Down reason) action
        newChild def workerSvQ spec

-- | Request to run an IO action with pooled thread.  Returns 'Async' on
-- success.  Returns 'Nothing' if pool is full or thread creation timed out.
run :: PoolQueue -> IO () -> IO (Maybe ThreadId)
run pool action = join <$> call def pool (Run action)

-- | Request to run an IO action with pooled thread.  Returns 'Async' on
-- success.  Wait until resource becomes available.  Returns 'Nothing' on
-- timeout.
runSync :: PoolQueue -> IO () -> IO (Maybe ThreadId)
runSync pool action = join <$> call def pool (RunSync action)

-- | Call runSync with wrapped by 'Async'.  Result (running thread) is passed to
-- continuation (callback).
runAsync :: PoolQueue -> IO () -> (Maybe ThreadId -> IO a) -> IO (Async a)
runAsync pool action cont = async $ runSync pool action >>= cont
