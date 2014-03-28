{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Chess.Search
       ( search
       , Search
       , runSearch
       , SearchState
       , mkSearchState
       , module Chess.SearchResult
       , board
       ) where

import           Control.Monad.State
import           Control.Lens

import           Data.ChessTypes
import           Chess.Board
import qualified Chess.TransPosCache as TPC
import           Chess.TransPosCache (result, typ)
import           Chess.Killer
import           Chess.SearchResult (SearchResult(..), eval, first, renderVariation)
import qualified Chess.SearchResult as SR ((<@>), (<++>), moves)
import           Chess.Evaluation
import           Chess.Move

data SearchState = SearchState
                   { _board    :: Board
                   , _tpc      :: TPC.TransPosCache
                   , _kill     :: Killer
                   , _tpcHit   :: ! Int
                   , _tpcMiss  :: ! Int
                   , _nCnt     :: ! Int                     
                   }

-- | Creates a search state with the initialBoard. Use the board Lens to manipulate the position in the SearchState
mkSearchState :: SearchState
mkSearchState = SearchState initialBoard TPC.mkTransPosCache mkKiller 0 0 0


$(makeLenses ''SearchState)


newtype Search a = Search { runSearch' :: StateT SearchState IO a }

-- | runs a search
runSearch :: Search a -> SearchState -> IO (a, SearchState)
runSearch = runStateT . runSearch'


instance Monad Search where
  return = Search . return
  (Search a) >>= f = Search $ a >>= runSearch' . f


instance MonadIO Search where
  liftIO = Search . liftIO


instance MonadState SearchState Search where
  get = Search get
  put = Search . put


(<@>) :: (Int -> Int) -> Search SearchResult -> Search SearchResult
f <@> m = liftM (f SR.<@>) m
(<++>) :: Move -> Search SearchResult -> Search SearchResult
x <++> m = liftM (x SR.<++>) m
    
data LoopResult = LoopResult
                  { _tpcEntryT :: ! TPC.TransPosCacheEntryType
                  , _line      :: ! SearchResult
                  }

$(makeLenses ''LoopResult)


-- | top level search
search
  :: Int -- ^ depth
  -> Search SearchResult
search d = do
  tpcHit   .= 0
  tpcMiss  .= 0
  nCnt     .= 0
  c <- liftM (\b -> direction (b^.next) 1) $ use board
  withIterativeDeepening d 1 $ \d' -> do
    r <- (c*) <@> negaScout d' d' (-inf) inf c
    kill .= insertPVInKiller (r^.SR.moves)
    return r


-- | searches with iterative deepening
withIterativeDeepening
  :: Int                -- ^ max depth
  -> Int                -- ^ start depth
  -> (Int -> Search a)  -- ^ search of given depth
  -> Search a
withIterativeDeepening mx d s = do
  liftIO $ putStrLn $ "info depth " ++ show d
  r <- s d
  if d >= mx
    then return r
    else withIterativeDeepening mx (d + 1) s


-- | executes search action with a moved played
withMove :: Move -> Search a -> Search a
withMove m ac = do
  old <- use board
  board %= makeMove m
  r <- ac
  board .= old
  return r
{-# INLINE withMove #-}


-- | executes a search action with a transpositional cache lookup
withTransPosCache
  :: Int -- ^ depth
  -> Int -- ^ alpha
  -> Int -- ^ beta
  -> (Int -> Int -> Maybe Move -> Search SearchResult)
  -> Search SearchResult
withTransPosCache d alpha beta f = do
  b <- use board
  t <- use tpc

  case TPC.transPosCacheLookUp b d t of
    
    Right (cache', entry) -> do
      tpc .= cache'
      tpcHit += 1
      case entry^.typ of
        TPC.Exact -> return $ entry^.result
        TPC.Lower -> let alpha' = max alpha $ entry^.result^.eval
                     in if alpha' >= beta
                        then return $ SearchResult [] alpha'
                        else f alpha' beta $ first $ entry^.result
        TPC.Upper -> let beta' = min beta $ entry^.result^.eval
                     in if alpha >= beta'
                        then return $ SearchResult [] alpha
                        else f alpha beta' $ first $ entry^.result
    Left mr -> do
      tpcMiss += 1
      f alpha beta mr
{-# INLINE withTransPosCache #-}


-- | iterates with killer heuristics
withKiller
  :: [ Move ] -- ^ move list
  -> Int      -- ^ max depth
  -> Int      -- ^ depth
  -> ( [ Move ] -> Search LoopResult)
  -> Search LoopResult  
withKiller ml mx d f = do
  ml' <- liftM (killer (mx - d) ml) (use kill)
  lr@(LoopResult t res) <- f ml'
  when (t == TPC.Lower) $ kill %= insertKiller (mx - d) (first res)
  return lr
{-# INLINE withKiller #-}


-- | iterates search on a move list
iterateMoves
  :: [ Move ]
  -> Int                                    -- ^ depth
  -> Int                                    -- ^ alpha
  -> Int                                    -- ^ beta
  -> Bool                                   -- ^ report info
  -> (Bool -> Move -> Int -> Int -> Search SearchResult) -- ^ True is fed in in the first iteration (for negascout)
  -> Search LoopResult
iterateMoves ml d alpha beta rep ac = do
  lr <- go True (LoopResult TPC.Upper $ SearchResult [] alpha) ml
  b  <- use board
  tpc %= TPC.transPosCacheInsert b d (lr^.tpcEntryT) (lr^.line)
  return lr
  where go _ l [] = return l
        go f prev (m:ms) = do
          let prevVal = prev^.line^.eval
          nxt <- ac f m prevVal beta
          let cont
                | nxt^.eval >= beta   = return $ LoopResult TPC.Lower $ SearchResult [m] beta
                | nxt^.eval > prevVal = info nxt m >> go False (LoopResult TPC.Exact nxt) ms
                | otherwise           = info (prev^.line) m >> go False prev ms
          cont
        info sr m = when rep $ get >>= \st -> liftIO $ putStrLn ("info TPC : " ++ show (hitRatio st) ++ "% "
                                                                 ++ show (st^.nCnt `div` 1000) ++ "kn "
                                                                 ++ " PV : " ++ renderVariation sr
                                                                 ++ " curr : " ++ renderShortMove m)

percentage :: Int -> Int -> Int
percentage a b = if a == 0 then 0 else 100 * b `div` a


hitRatio :: SearchState -> Int
hitRatio st = percentage ((st^.tpcHit) + (st^.tpcMiss)) (st^.tpcHit)


-- | The negascout search with transpos cache and killer.
negaScout
  :: Int -- ^ max depth
  -> Int -- ^ depth
  -> Int -- ^ alpha
  -> Int -- ^ beta
  -> Int -- ^ colour
  -> Search SearchResult
negaScout mx d alpha' beta' c = withTransPosCache d alpha' beta' $ \alpha beta mr -> do
  mate <- liftM (not . anyMove) $ use board
  if mate
    then do
      nCnt += 1
      liftM (\b -> SearchResult [] $ c * evaluate b) $ use board
    else if d == 0
          then quiscene alpha beta c
          else do
            ml <- getMoveList mr moves

            r <- withKiller ml mx d
                 $ \ml' -> iterateMoves ml' d alpha beta (mx == d)
                           $ \f m a b -> withMove m
                                         $ m <++>
                                         if not f
                                         then do
                                           n <- ((-1)*) <@> negaScout mx (d - 1) (-a - 1) (-a) (-c)
                                           if a < n^.eval && n^.eval < b
                                             then ((-1)*) <@> negaScout mx (d - 1) (-b) (-a) (-c)
                                             else return n
                                         else ((-1)*) <@> negaScout mx (d - 1) (-b) (-a) (-c)
            return $ r^.line


-- | quiscene search
quiscene :: Int -> Int -> Int -> Search SearchResult
quiscene alpha' beta' c = withTransPosCache 0 alpha' beta' $ \alpha beta mr -> do
  standPat <- liftM ((c*) . evaluate) (use board)
  nCnt += 1
  if standPat >= beta
    then do
       b  <- use board
       tpc %= TPC.transPosCacheInsert b 0 TPC.Lower (SearchResult [] beta)
       return $ SearchResult [] beta 
    else do
       ml <- getMoveList mr forcingMoves
       let mx = max alpha standPat
       r <- iterateMoves ml 0 mx beta False $
         \ _ m a b -> withMove m $ m <++> (((-1)*) <@> quiscene (-b) (-a) (-c))
       return $ r^.line



getMoveList :: Maybe Move -> (Board -> [Move]) -> Search [Move]
getMoveList mr mvs = liftM (addMaybeMove mr . mvs) $ use board
{-# INLINE getMoveList #-}


inf :: Int
inf = maxBound


addMaybeMove :: (Eq a) => Maybe a -> [a] -> [a]
addMaybeMove mr l = maybe l (\m -> m : filter (/= m) l) mr
{-# INLINE addMaybeMove #-}
