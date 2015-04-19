module Prometheus.Metric.Summary (
    Summary
,   Quantile
,   summary
,   defaultQuantiles
,   observe
,   getSummary

,   dumpEstimator

,   Estimator (..)
,   Item (..)
,   insert
,   compress
,   query
) where

import Prometheus.Info
import Prometheus.Metric
import Prometheus.MonadMetric

import Data.Int (Int64)
import Data.List (partition)
import qualified Control.Concurrent.STM as STM
import qualified Data.ByteString.UTF8 as BS


newtype Summary = MkSummary (STM.TVar Estimator)

summary :: Info -> [Quantile] -> MetricGen Summary
summary info quantiles = do
    valueTVar <- STM.newTVarIO (emptyEstimator quantiles)
    return Metric {
            handle = MkSummary valueTVar
        ,   collect = collectSummary info valueTVar
        }

withSummary :: MonadMetric m
            => Metric Summary -> (Estimator -> Estimator) -> m ()
withSummary (Metric {handle = MkSummary valueTVar}) f =
    doIO $ STM.atomically $ STM.modifyTVar' valueTVar f

observe :: MonadMetric m => Double -> Metric Summary -> m ()
observe v summary = withSummary summary (insert v)

getSummary :: Metric Summary -> IO [(Double, Double)]
getSummary (Metric {handle = MkSummary valueTVar}) = do
    estimator <- STM.atomically $ do
        STM.modifyTVar' valueTVar compress
        STM.readTVar valueTVar
    let quantiles = map fst $ estQuantiles estimator
    let values = map (query estimator) quantiles
    return $ zip quantiles values

collectSummary :: Info -> STM.TVar Estimator -> IO [SampleGroup]
collectSummary info valueTVar = STM.atomically $ do
    STM.modifyTVar' valueTVar compress
    estimator@(Estimator count itemSum _ _) <- STM.readTVar valueTVar
    let quantiles = map fst $ estQuantiles estimator
    let samples =  map (toSample estimator) quantiles
    let sumSample = Sample (metricName info ++ "_sum") [] (bsShow itemSum)
    let countSample = Sample (metricName info ++ "_count") [] (bsShow count)
    return [SampleGroup info SummaryType $ samples ++ [sumSample, countSample]]
    where
        bsShow :: Show s => s -> BS.ByteString
        bsShow = BS.fromString . show

        toSample estimator q = Sample (metricName info) [("quantile", show q)]
                             $ bsShow $ query estimator q

dumpEstimator :: Metric Summary -> IO Estimator
dumpEstimator (Metric {handle = MkSummary valueTVar}) =
    STM.atomically $ STM.readTVar valueTVar

-- | A quantile is a pair of a quantile value and an associated acceptable error
-- value.
type Quantile = (Double, Double)

data Item = Item {
    itemValue :: Double
,   itemG     :: Double
,   itemD     :: Double
} deriving (Eq, Show)

instance Ord Item where
    compare a b = itemValue a `compare` itemValue b

data Estimator = Estimator {
    estCount      :: !Int64
,   estSum        :: !Double
,   estQuantiles  :: [Quantile]
,   estItems      :: [Item]
} deriving (Show)

defaultQuantiles :: [Quantile]
defaultQuantiles = [(0.5, 0.05), (0.9, 0.01), (0.99, 0.001)]

emptyEstimator :: [Quantile] -> Estimator
emptyEstimator quantiles = Estimator 0 0 quantiles []

insert :: Double -> Estimator -> Estimator
insert value estimator@(Estimator oldCount oldSum quantiles items)
    | null smaller = newEstimator $ insertBag itemEnd items
    | null larger  = newEstimator $ insertBag itemEnd items
    | otherwise    = newEstimator $ insertBag itemMiddle items
    where
        newEstimator = Estimator (oldCount + 1) (oldSum + value) quantiles

        itemEnd = Item value 1 0
        itemMiddle = Item value 1 $ invariant estimator r

        (smaller, larger) = partition ((< value) . itemValue) items
        r = sum $ map itemG smaller

        insertBag a [] = [a]
        insertBag a (x:xs) | a < x     = a : x : xs
                           | otherwise = x : insertBag a xs

compress :: Estimator -> Estimator
compress est@(Estimator _ _ _ items) = est {
        estItems = compressItems [] items
    }
    where
        compressItems prev []  = reverse prev
        compressItems prev [a] = reverse $ a : prev
        compressItems prev (i1@(Item _ g1 _) : i2@(Item v2 g2 d2) : xs)
            | g1 + g2 + d2 < inv = compressItems prev (Item v2 (g1 + g2) d2:xs)
            | otherwise          = compressItems (i1:prev) (i2:xs)
            where
                r1 = sum $ map itemG prev
                inv = invariant est r1

query :: Estimator -> Double -> Double
query est@(Estimator count _ _ items) q = findQuantile rs items
    where
        rs = zipWith (+) (0 : rs) (map itemG items)

        n = fromIntegral count
        f = invariant est

        findQuantile _        []            = 0
        findQuantile _        [a]           = itemValue a
        findQuantile (_:r:rs) (a:b@(Item _ g d):xs)
            | r + g + d > q * n + f (q * n) = itemValue a
            | otherwise                     = findQuantile (r:rs) (b:xs)
        findQuantile _        _             = error "Unmatched R and items"

invariant :: Estimator -> Double -> Double
invariant (Estimator count _ quantiles _) r = minimum $ map fj quantiles
    where
        n = fromIntegral count
        fj (q, e) | q * n <= r && r <= n = 2 * e * r / q
                  | otherwise            = 2 * e * (n - r) / (1 - q)
