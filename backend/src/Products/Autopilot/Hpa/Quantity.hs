{-# LANGUAGE OverloadedStrings #-}

{- | Kubernetes @resource.Quantity@ parsing and comparison.

HPA targets (@averageValue@, @value@) and anything we diff against the live
object are Quantities: @500m@ == @0.5@, @1Gi@ == @1024Mi@ == @1073741824@,
and @1G@ (decimal) /= @1Gi@. Comparing the raw strings would report false
drift and false verify failures, so equality is on the canonical value
(milli-units, rounded up exactly as the API server does) while the original
spelling is kept for display and for writing the object back unchanged.
-}
module Products.Autopilot.Hpa.Quantity (
    Quantity,
    qRaw,
    qMilli,
    parseQuantity,
    mkQuantity,
)
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..))
import Data.Char (isDigit)
import Data.Ratio (denominator, numerator, (%))
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T

data Quantity = Quantity
    { qRaw :: Text
    -- ^ Original spelling, preserved for display and round-tripping.
    , qMilli :: Integer
    -- ^ Canonical value in milli-units (1 CPU = 1000, 1 byte = 1000).
    }
    deriving (Show)

-- | Equality and ordering are on the value, never on the spelling.
instance Eq Quantity where
    a == b = qMilli a == qMilli b

instance Ord Quantity where
    compare a b = compare (qMilli a) (qMilli b)

instance ToJSON Quantity where
    toJSON = String . qRaw

-- | The API serialises quantities as strings; bare numbers are accepted too.
instance FromJSON Quantity where
    parseJSON (String t) = either (fail . T.unpack) pure (parseQuantity t)
    parseJSON (Number n) =
        let t = case floatingOrInteger n :: Either Double Integer of
                Right i -> T.pack (show i)
                Left d -> T.pack (show d)
         in either (fail . T.unpack) pure (parseQuantity t)
    parseJSON _ = fail "quantity must be a string or number"

-- | Build from a plain integer of base units (e.g. @mkQuantity 2@ = 2 CPUs).
mkQuantity :: Integer -> Quantity
mkQuantity n = Quantity (T.pack (show n)) (n * 1000)

parseQuantity :: Text -> Either Text Quantity
parseQuantity raw0 = do
    let raw = T.strip raw0
    (sign, body) <- case T.uncons raw of
        Just ('-', r) -> Right (-1, r)
        Just ('+', r) -> Right (1, r)
        Just _ -> Right (1, raw)
        Nothing -> Left "empty quantity"
    let (intPart, afterInt) = T.span isDigit body
        (fracPart, rest) = case T.uncons afterInt of
            Just ('.', r) -> T.span isDigit r
            _ -> ("", afterInt)
    if T.null intPart && T.null fracPart
        then Left ("invalid quantity: " <> raw)
        else do
            mult <- suffixMultiplier rest raw
            let digits = intPart <> fracPart
                mantissa = if T.null digits then 0 else read (T.unpack digits) :: Integer
                scale = 10 ^ T.length fracPart :: Integer
                value = sign * (mantissa % scale) * mult
                milli = ceilingRatio (value * 1000)
            Right (Quantity raw milli)
  where
    ceilingRatio r =
        let (q, m) = numerator r `divMod` denominator r
         in if m == 0 then q else q + 1

-- | Multiplier for a suffix: SI, binary-SI, or a decimal exponent (@e3@, @E-2@).
suffixMultiplier :: Text -> Text -> Either Text Rational
suffixMultiplier suf raw = case suf of
    "" -> Right 1
    "n" -> Right (1 % 1000000000)
    "u" -> Right (1 % 1000000)
    "m" -> Right (1 % 1000)
    "k" -> Right (10 ^ (3 :: Int))
    "M" -> Right (10 ^ (6 :: Int))
    "G" -> Right (10 ^ (9 :: Int))
    "T" -> Right (10 ^ (12 :: Int))
    "P" -> Right (10 ^ (15 :: Int))
    "E" -> Right (10 ^ (18 :: Int))
    "Ki" -> Right (2 ^ (10 :: Int))
    "Mi" -> Right (2 ^ (20 :: Int))
    "Gi" -> Right (2 ^ (30 :: Int))
    "Ti" -> Right (2 ^ (40 :: Int))
    "Pi" -> Right (2 ^ (50 :: Int))
    "Ei" -> Right (2 ^ (60 :: Int))
    _ -> case T.uncons suf of
        -- "1E" alone is exa (handled above); "1E3" / "1e-3" is an exponent.
        Just (c, expo) | c == 'e' || c == 'E' -> exponent' expo
        _ -> Left ("invalid quantity suffix in: " <> raw)
  where
    exponent' expo =
        let (esign, digits) = case T.uncons expo of
                Just ('-', r) -> (-1, r)
                Just ('+', r) -> (1, r)
                _ -> (1, expo)
         in if T.null digits || not (T.all isDigit digits)
                then Left ("invalid quantity exponent in: " <> raw)
                else
                    let e = esign * read (T.unpack digits) :: Integer
                     in if abs e > 30
                            then Left ("quantity exponent out of range in: " <> raw)
                            else Right (if e >= 0 then fromInteger (10 ^ e) else 1 % (10 ^ negate e))
