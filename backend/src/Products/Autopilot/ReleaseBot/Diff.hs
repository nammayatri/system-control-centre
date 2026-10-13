{-# LANGUAGE OverloadedStrings #-}

{- | Pure line diff + base64 decoding for the release bot's env/configmap review.

'diffLines' is an LCS diff (common prefix/suffix trimmed first). If the
differing middle is too large for the O(n*m) table, it degrades to "delete
everything old, add everything new" — still a correct diff, just not minimal.
-}
module Products.Autopilot.ReleaseBot.Diff (
    DiffLine (..),
    Hunk (..),
    FileDiff (..),
    diffLines,
    hunks,
    diffText,
    decodeB64Text,
    encodeB64Text,
    changedCount,
) where

import Control.Monad (forM_)
import Control.Monad.ST (ST, runST)
import Data.Aeson (ToJSON (..), object, (.=))
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM

data DiffLine = Ctx Text | Del Text | Add Text
    deriving (Show, Eq)

data Hunk = Hunk
    { hOldStart :: Int
    , hNewStart :: Int
    , hLines :: [DiffLine]
    }
    deriving (Show, Eq)

-- | Diff of one logical file (a configmap key, or the decoded env var).
data FileDiff = FileDiff
    { fdName :: Text
    , fdHunks :: [Hunk]
    , fdAdded :: Int
    , fdRemoved :: Int
    }
    deriving (Show, Eq)

instance ToJSON DiffLine where
    toJSON (Ctx t) = object ["t" .= ("ctx" :: Text), "text" .= t]
    toJSON (Del t) = object ["t" .= ("del" :: Text), "text" .= t]
    toJSON (Add t) = object ["t" .= ("add" :: Text), "text" .= t]

instance ToJSON Hunk where
    toJSON h = object ["oldStart" .= hOldStart h, "newStart" .= hNewStart h, "lines" .= hLines h]

instance ToJSON FileDiff where
    toJSON f = object ["name" .= fdName f, "hunks" .= fdHunks f, "added" .= fdAdded f, "removed" .= fdRemoved f]

-- | Largest LCS table (old*new cells) we are willing to build.
maxCells :: Int
maxCells = 40000000

diffLines :: [Text] -> [Text] -> [DiffLine]
diffLines old new =
    let pre = length (takeWhile id (zipWith (==) old new))
        (preL, oldR) = splitAt pre old
        newR = drop pre new
        -- trim common suffix of the remainders
        revO = reverse oldR
        revN = reverse newR
        suf = length (takeWhile id (zipWith (==) revO revN))
        oldM = reverse (drop suf revO)
        newM = reverse (drop suf revN)
        sufL = reverse (take suf revO)
     in map Ctx preL ++ diffMiddle oldM newM ++ map Ctx sufL

diffMiddle :: [Text] -> [Text] -> [DiffLine]
diffMiddle [] ns = map Add ns
diffMiddle os [] = map Del os
diffMiddle os ns
    | n * m > maxCells = map Del os ++ map Add ns
    | otherwise = backtrack ov nv (lcsTable ov nv)
  where
    ov = V.fromList os
    nv = V.fromList ns
    n = V.length ov
    m = V.length nv

-- | (n+1)*(m+1) table of suffix-LCS lengths, row-major.
lcsTable :: V.Vector Text -> V.Vector Text -> VU.Vector Int
lcsTable ov nv = runST build
  where
    n = V.length ov
    m = V.length nv
    w = m + 1
    build :: ST s (VU.Vector Int)
    build = do
        t <- VUM.replicate ((n + 1) * w) 0
        forM_ [n - 1, n - 2 .. 0] $ \i ->
            forM_ [m - 1, m - 2 .. 0] $ \j ->
                if ov V.! i == nv V.! j
                    then VUM.read t ((i + 1) * w + (j + 1)) >>= VUM.write t (i * w + j) . (+ 1)
                    else do
                        a <- VUM.read t ((i + 1) * w + j)
                        b <- VUM.read t (i * w + (j + 1))
                        VUM.write t (i * w + j) (max a b)
        VU.freeze t

backtrack :: V.Vector Text -> V.Vector Text -> VU.Vector Int -> [DiffLine]
backtrack ov nv t = go 0 0
  where
    n = V.length ov
    m = V.length nv
    w = m + 1
    at i j = t VU.! (i * w + j)
    go i j
        | i >= n && j >= m = []
        | i >= n = Add (nv V.! j) : go i (j + 1)
        | j >= m = Del (ov V.! i) : go (i + 1) j
        | ov V.! i == nv V.! j = Ctx (ov V.! i) : go (i + 1) (j + 1)
        | at (i + 1) j >= at i (j + 1) = Del (ov V.! i) : go (i + 1) j
        | otherwise = Add (nv V.! j) : go i (j + 1)

changedCount :: [DiffLine] -> (Int, Int)
changedCount ls = (length [() | Add _ <- ls], length [() | Del _ <- ls])

-- | Group a diff into hunks with @ctx@ lines of context. No changes -> no hunks.
hunks :: Int -> [DiffLine] -> [Hunk]
hunks ctx ls =
    let indexed = zip3 [0 :: Int ..] (positions ls) ls
        changed = [i | (i, _, l) <- indexed, isChange l]
     in case changed of
            [] -> []
            _ -> map (mk indexed) (ranges changed)
  where
    isChange (Ctx _) = False
    isChange _ = True
    -- (oldLineNo, newLineNo) 1-based of the *start* of each line
    positions = go 1 1
      where
        go _ _ [] = []
        go o n (l : rest) = (o, n) : case l of
            Ctx _ -> go (o + 1) (n + 1) rest
            Del _ -> go (o + 1) n rest
            Add _ -> go o (n + 1) rest
    total = length ls
    ranges is = merge [(max 0 (i - ctx), min (total - 1) (i + ctx)) | i <- is]
    merge ((a, b) : (c, d) : rest)
        | c <= b + 1 = merge ((a, max b d) : rest)
        | otherwise = (a, b) : merge ((c, d) : rest)
    merge xs = xs
    mk indexed (a, b) =
        let slice = [x | x@(i, _, _) <- indexed, i >= a, i <= b]
         in case slice of
                ((_, (o, n), _) : _) -> Hunk o n [l | (_, _, l) <- slice]
                [] -> Hunk 0 0 []

-- | Diff two texts and package as a 'FileDiff' (3 lines of context).
diffText :: Text -> Text -> Text -> FileDiff
diffText name old new =
    let dl = diffLines (T.lines old) (T.lines new)
        (a, r) = changedCount dl
     in FileDiff{fdName = name, fdHunks = hunks 3 dl, fdAdded = a, fdRemoved = r}

-- | Strict base64 -> UTF-8 text. 'Left' (never a lossy guess) when the value is
-- not valid base64 or not valid UTF-8, so callers can fail closed.
decodeB64Text :: Text -> Either Text Text
decodeB64Text t =
    case B64.decode (TE.encodeUtf8 (T.filter (\c -> c /= '\n' && c /= '\r' && c /= ' ') t)) of
        Left e -> Left ("not valid base64: " <> T.pack e)
        Right bs -> case TE.decodeUtf8' bs of
            Left (TEE.DecodeError msg _) -> Left ("decoded value is not UTF-8: " <> T.pack msg)
            Left _ -> Left "decoded value is not UTF-8"
            Right x -> Right x

encodeB64Text :: Text -> Text
encodeB64Text = TE.decodeUtf8 . B64.encode . TE.encodeUtf8

