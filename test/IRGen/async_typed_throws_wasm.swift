// RUN: %target-swift-frontend -primary-file %s -emit-ir -parse-as-library \
// RUN:   -disable-availability-checking | %FileCheck %s

// REQUIRES: concurrency

// Verifies the async typed-throws LLVM IR layout: ind_error is placed
// BEFORE swiftself in the entry signature so Thin and Thick callers
// agree on the LLVM-IR position of the typed-error indirect pointer.
// This file targets the HOST (the layout reorder applies uniformly to
// all targets) and accepts both `swiftcc` and `swifttailcc` because
// `SwiftAsyncCC` resolves differently per target. The wasi runtime
// suite also covers the wasm-bytecode-level mismatch via
// Interpreter/async_typed_throws_wasm.swift.

struct LargeErr: Error {
  var tag: Int
  var pad: (Int, Int, Int, Int)
}

struct LargeResult {
  var tag: Int
  var pad: (Int, Int, Int, Int, Int, Int, Int, Int)
}

protocol PAsync {
  associatedtype Failure: Error
  associatedtype Output
  func boom() async throws(Failure) -> Output
}

struct ImplPAsync: PAsync {
  typealias Failure = LargeErr
  typealias Output = LargeResult
  func boom() async throws(LargeErr) -> LargeResult {
    throw LargeErr(tag: 1, pad: (0, 0, 0, 0))
  }
}

func run<T, Failure: Error>(
  _ body: () async throws(Failure) -> T
) async -> Result<T, Failure> {
  do { return .success(try await body()) }
  catch { return .failure(error) }
}

func runWitness<T: PAsync>(_ x: T) async -> Result<T.Output, T.Failure> {
  do { return .success(try await x.boom()) }
  catch { return .failure(error) }
}

@main
struct Main {
  static func main() async {
    let r = await run { () async throws(LargeErr) -> LargeResult in
      throw LargeErr(tag: 2, pad: (0, 0, 0, 0))
    }
    _ = r
    let w = await runWitness(ImplPAsync())
    _ = w
  }
}

// Witness-method thunk for async typed-throws: under the NEW layout
// the trailing pair is [ind_error, swiftself], followed by Self + WT.
// CHECK-LABEL: define internal {{(swifttailcc|swiftcc)}} void @"$s{{[^"]+}}P4boom6OutputQzyYa7FailureQzYKFTW"
// CHECK-SAME: (ptr noalias{{[^,]*}} %{{[0-9]+}}, ptr swiftasync %{{[0-9]+}}, ptr %{{[0-9]+}}, ptr noalias{{[^,]*}} swiftself{{[^,]*}} %{{[0-9]+}}, ptr %{{[0-9_a-zA-Z]+}}, ptr %{{[0-9_a-zA-Z]+}})

// Thin async typed-throws closure literal: ind_result, swiftasync,
// ind_error. No swiftself.
// CHECK-LABEL: define internal {{(swifttailcc|swiftcc)}} void @"$s{{[^"]+}}fU_"
// CHECK-SAME: (ptr noalias{{[^,]*}} %{{[0-9]+}}, ptr swiftasync %{{[0-9]+}}, ptr %{{[0-9]+}})

// Negative assertion: the witness thunk MUST NOT have the OLD pre-fix
// layout `[..., swiftself, ind_error, Self, WT]` (3 trailing ptr params
// after swiftself). The new layout has exactly 2 trailing ptrs after
// swiftself (Self + WT).
// CHECK-NOT: define internal {{(swifttailcc|swiftcc)}} void @"$s{{[^"]+}}P4boom6OutputQzyYa7FailureQzYKFTW"({{[^)]*}}swiftself{{[^,]*}}, ptr %{{[0-9]+}}, ptr %{{[0-9_a-zA-Z]+}}, ptr %{{[0-9_a-zA-Z]+}})
