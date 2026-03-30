module Main where

import Data.Text (pack)
import NammaAP.K8s.Kubectl (isIdempotentSuccess, K8sError (..))

main :: IO ()
main = do
  if isIdempotentSuccess (K8sError (pack "AlreadyExists"))
    then putStrLn "tests-passed"
    else fail "idempotency test failed"
