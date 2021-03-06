-- | This module allows for the tracking of source span changes.
--
-- This allows us to associate information from a prior editor state
-- with the current editor state.  It provides a map from old source
-- spans to new source spans, such that you can ask "Where was this
-- span when the code was compiled?" - mapping spans backward in time.
-- The current implementation simply stores a list of span
-- replacements, and then replays history, offseting the input span.
--
-- It also allows you to map spans forward in time, from the compiled
-- state to the current state.  This lets you take spans yielded by
-- the compiler and map them to spans in the buffer.
--
-- Often, it isn't possible to map a span forwards / backwards,
-- because an edit has happened with that region.  In order to still
-- get a result, we'd need to have defaults for these circumstances.
module View.PosMap
  (
  -- * School-of-haskell specific utilities
    handleChange
  , selectionToSpan
  , spanToSelection
  , rangeToSpan
  , spanToRange
  -- * Implementation
  , emptyPosMap
  , rangeMapForward
  , rangeMapBackward
  , posMapForward
  , posMapBackward
  , changeEventToPosChange
  ) where

import JavaScript.Ace
import Data.List (foldl')
import Import

--------------------------------------------------------------------------------
-- School-of-haskell specific utilities

-- | Given the event generated by a text change in the Ace editor,
-- this updates the 'PosMap' for the snippet.
handleChange :: TVar State -> SnippetId -> ChangeEvent -> IO ()
handleChange state sid ev =
  modifyTVarIO state
               (ixSnippet sid . snippetPosMap . _Wrapped)
               (changeEventToPosChange ev :)

selectionToSpan :: State -> SnippetId -> Selection -> Maybe SourceSpan
selectionToSpan state sid =
  rangeToSpan state sid . selectionToRange

spanToSelection :: State -> SnippetId -> SourceSpan -> Maybe Selection
spanToSelection state sid =
  fmap rangeToSelection . spanToRange state sid

rangeToSpan :: State -> SnippetId -> Range -> Maybe SourceSpan
rangeToSpan state sid range = do
  posMap <- state ^? ixSnippet sid . snippetPosMap
  rangeToSpan' "main.hs" <$> (rangeMapBackward posMap range)

spanToRange :: State -> SnippetId -> SourceSpan -> Maybe Range
spanToRange state sid ss = do
    posMap <- state ^? ixSnippet sid . snippetPosMap
    rangeMapForward posMap r
  where
    -- TODO: do something with the filepath.
    (_fp, r) = spanToRange' ss

rangeToSpan' :: FilePath -> Range -> SourceSpan
rangeToSpan' fp Range{..} = SourceSpan
  { spanFilePath   = fp
  , spanFromLine   = row    start + 1
  , spanFromColumn = column start + 1
  , spanToLine     = row    end   + 1
  , spanToColumn   = column end   + 1
  }

spanToRange' :: SourceSpan -> (FilePath, Range)
spanToRange' SourceSpan{..} = (spanFilePath, range)
  where
    range = Range
      { start = Pos (spanFromLine - 1) (spanFromColumn - 1)
      , end = Pos (spanToLine - 1) (spanToColumn - 1)
      }

--------------------------------------------------------------------------------
-- Implementation

-- TODO: this is rather inefficient.  Adjustments will get slower and
-- slower as more edits are added since the last compile.  I think a
-- more efficient implementation of this would use something like
-- "Data.FingerTree".  A rough sketch I haven't thought that much
-- about:
--
-- type PosMap = FingerTree PosMeasure PosChange
--
-- data PosMeasure = PosMeasure
--   { posInOld :: Pos -- ^ For the fingertree subtree, this stores the start
                       -- position of the leftmost node.  This allows us to
                       -- search for a particular position in the old state.
--   , posInNew :: Pos -- ^ Similarly to the above, but for the new state.
--   }

emptyPosMap :: PosMap
emptyPosMap = PosMap []

-- | Maps a range forwards in time.  In other words, given a range
-- from before the user edited the code, this figures out how that
-- range would be shifted.  If an edit occurred within the range, then
-- 'Nothing' is yielded.
rangeMapForward :: PosMap -> Range -> Maybe Range
rangeMapForward =
  mapImpl oldRange newRange shiftRange compareRange . reverse . unPosMap

-- | Maps a range forwards in time.  In other words, given a range in
-- the current code state, this figures out where that range came
-- from, before the user's edits.  If an edit occurred within the
-- range, then 'Nothing' is yielded.
rangeMapBackward :: PosMap -> Range -> Maybe Range
rangeMapBackward =
  mapImpl newRange oldRange shiftRange compareRange . unPosMap

-- | Similar to 'rangeMapForward', but instead maps a position.
posMapForward :: PosMap -> Pos -> Maybe Pos
posMapForward =
  mapImpl oldRange newRange shiftPos comparePosWithRange . reverse . unPosMap

-- | Similar to 'rangeMapBackward', but instead maps a position.
posMapBackward :: PosMap -> Pos -> Maybe Pos
posMapBackward =
  mapImpl newRange oldRange shiftPos comparePosWithRange . unPosMap

mapImpl
  :: (PosChange -> Range)
  -> (PosChange -> Range)
  -> (DeltaPos -> a -> a)
  -> (a -> Range -> RangeOrdering)
  -> [PosChange]
  -> a
  -> Maybe a
mapImpl before after shift comp changes p0 =
    foldl' go (Just p0) changes
  where
    go Nothing _ = Nothing
    go (Just x) change =
      case x `comp` (before change) of
        -- Replacements don't affect positions that come earlier in the buffer.
        Before -> Just x
        -- If the position is inside an interval that got replaced,
        -- then it maps to Nothing.
        Intersecting -> Nothing
        -- The replacement moved this position, so offset it.
        After -> Just $ shift delta x
          where
            delta = end (after change) `subtractPos` end (before change)

changeEventToPosChange :: ChangeEvent -> PosChange
changeEventToPosChange ev =
  case ev of
    InsertLines range _ -> PosChange
      { oldRange = startRange range, newRange = range            }
    InsertText range _ -> PosChange
      { oldRange = startRange range, newRange = range            }
    RemoveLines range _ _ -> PosChange
      { oldRange = range           , newRange = startRange range }
    RemoveText range _ -> PosChange
      { oldRange = range           , newRange = startRange range }
  where
    startRange range = Range (start range) (start range)
