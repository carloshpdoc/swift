// RUN: %empty-directory(%t)
// RUN: %target-build-swift -parse-as-library -Onone %s -o %t/main
// RUN: %target-run %t/main | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: concurrency_runtime
// REQUIRES: OS=wasip1

enum SmallErr: Error { case boom }

struct LargeErr: Error {
  var tag: Int
  var pad: (Int, Int, Int, Int)
}

struct LargeResult {
  var tag: Int
  var pad: (Int, Int, Int, Int, Int, Int, Int, Int)
}

func run<T, Failure: Error>(
  _ body: () async throws(Failure) -> T
) async -> Result<T, Failure> {
  do { return .success(try await body()) }
  catch { return .failure(error) }
}

func runIdent(_ body: () async -> String) async -> String {
  await body()
}

// For shape h: stored function pointer (forces non-FunctionRef SIL operand).
enum StoredClosure {
  static let boomClosure: () async throws(SmallErr) -> String = {
    throw SmallErr.boom
  }
}

// For shape j: witness-method async typed-throws.
protocol AsyncBoom {
  associatedtype Failure: Error
  func boom() async throws(Failure) -> String
}

struct BoomThrower: AsyncBoom {
  typealias Failure = SmallErr
  func boom() async throws(SmallErr) -> String { throw .boom }
}

func invokeWitness<T: AsyncBoom>(_ x: T) async -> Result<String, T.Failure> {
  do { return .success(try await x.boom()) }
  catch { return .failure(error) }
}

// For shape k: Thick self-context (actor method invoking a typed-throws closure).
actor BoomActor {
  func run() async -> Result<String, SmallErr> {
    do {
      return .success(try await { () async throws(SmallErr) -> String in
        throw SmallErr.boom
      }())
    } catch {
      return .failure(error)
    }
  }
}

// For shape q: witness-method x LargeErr.
protocol LargeAsync {
  func boom() async throws(LargeErr) -> String
}
struct LargeBoom: LargeAsync {
  func boom() async throws(LargeErr) -> String {
    throw LargeErr(tag: 11, pad: (0, 0, 0, 0))
  }
}
func invokeLarge<T: LargeAsync>(_ x: T) async -> Result<String, LargeErr> {
  do { return .success(try await x.boom()) }
  catch { return .failure(error) }
}

// For shape r: actor cross-isolation with large typed error.
actor LargeActor {
  func bang() async throws(LargeErr) -> String {
    throw LargeErr(tag: 13, pad: (0, 0, 0, 0))
  }
}

// For shape s: @MainActor + async typed-throws with large error.
@MainActor
func mainLargeErr() async throws(LargeErr) -> String {
  throw LargeErr(tag: 17, pad: (0, 0, 0, 0))
}

// For shape t: replica of stdlib Result.init(catching:) added by
// PR 88465. None of shapes a-s combines (init) + (nonisolated(nonsending)
// on both init and body parameter) + (Success: ~Copyable extension) +
// (@_alwaysEmitIntoClient) + (generic Failure inferred as any Error from
// untyped-throws closure literal). The SIL band-aid's polymorphic-skip
// predicate at WasmAsyncT2TLowering.cpp:56-57 (on main) bypasses this
// t2t shape, which is why stdlib/Result.swift trips on wasi CI under
// the band-aid but not under the IRGen reorder this branch implements.
enum MyResult<Success: ~Copyable, Failure: Error>: ~Copyable {
  case success(Success)
  case failure(Failure)
}
extension MyResult: Copyable where Success: Copyable {}

extension MyResult where Success: ~Copyable {
  @_alwaysEmitIntoClient
  nonisolated(nonsending) init(
    catching body: nonisolated(nonsending) () async throws(Failure) -> Success
  ) async {
    do {
      self = .success(try await body())
    } catch {
      self = .failure(error)
    }
  }
}

@main
struct Main {
  static func main() async {
    // a: untyped throws (the issue #89320 repro shape).
    let a = await run { () async throws -> String in throw SmallErr.boom }
    switch a {
    case .success(let s): print("a-ok: \(s)")
    case .failure(let e): print("a-err: \(e)")
    }
    // CHECK: a-err: boom

    // b: typed throws, small error enum.
    let b = await run { () async throws(SmallErr) -> String in
      throw SmallErr.boom
    }
    switch b {
    case .success(let s): print("b-ok: \(s)")
    case .failure(let e): print("b-err: \(e)")
    }
    // CHECK-NEXT: b-err: boom

    // c: typed throws, large error struct (forces ind_error indirection).
    let c = await run { () async throws(LargeErr) -> String in
      throw LargeErr(tag: 42, pad: (0, 0, 0, 0))
    }
    switch c {
    case .success(let s): print("c-ok: \(s)")
    case .failure(let e): print("c-err: tag=\(e.tag)")
    }
    // CHECK-NEXT: c-err: tag=42

    // d: success path, no throws taken.
    let d = await run { () async throws -> String in "yay" }
    switch d {
    case .success(let s): print("d-ok: \(s)")
    case .failure(let e): print("d-err: \(e)")
    }
    // CHECK-NEXT: d-ok: yay

    // e: non-throws closure passed through a t2t, exercises the
    // predicate's negative branch (no indirect error result, so predicate
    // returns false and no wrapper is emitted; default lowering).
    let e = await runIdent { () async -> String in "noerror" }
    print("e-ok: \(e)")
    // CHECK-NEXT: e-ok: noerror

    // f: generic async typed-throws via explicit type argument
    // (R3 — polymorphic SIL function type rejected by SIL workaround).
    let f: Result<String, SmallErr> = await run {
      () async throws(SmallErr) -> String in throw SmallErr.boom
    }
    switch f {
    case .success(let s): print("f-ok: \(s)")
    case .failure(let e): print("f-err: \(e)")
    }
    // CHECK-NEXT: f-err: boom

    // g: t2t fed by phi/block-arg operand (R4 — non-FunctionRef rejected).
    let cond = Bool.random()
    let g: Result<String, SmallErr> = await run {
      () async throws(SmallErr) -> String in
        if cond { throw SmallErr.boom } else { throw SmallErr.boom }
    }
    switch g {
    case .success(let s): print("g-ok: \(s)")
    case .failure(let e): print("g-err: \(e)")
    }
    // CHECK-NEXT: g-err: boom

    // h: closure loaded from a stored global (R4 — non-FunctionRef operand).
    let h: Result<String, SmallErr> = await run(StoredClosure.boomClosure)
    switch h {
    case .success(let s): print("h-ok: \(s)")
    case .failure(let e): print("h-err: \(e)")
    }
    // CHECK-NEXT: h-err: boom

    // i: t2t result used across BBs (R5 — cross-BB use rejected).
    var iResult: Result<String, SmallErr>?
    let iClosure: () async throws(SmallErr) -> String = {
      throw SmallErr.boom
    }
    if Bool.random() || true {
      iResult = await run(iClosure)
    }
    switch iResult! {
    case .success(let s): print("i-ok: \(s)")
    case .failure(let e): print("i-err: \(e)")
    }
    // CHECK-NEXT: i-err: boom

    // j: witness-method async typed-throws (R3 via Self-as-polymorphic).
    let j = await invokeWitness(BoomThrower())
    switch j {
    case .success(let s): print("j-ok: \(s)")
    case .failure(let e): print("j-err: \(e)")
    }
    // CHECK-NEXT: j-err: boom

    // k: Thick-self-context async typed-throws (actor isolation).
    let k = await BoomActor().run()
    switch k {
    case .success(let s): print("k-ok: \(s)")
    case .failure(let e): print("k-err: \(e)")
    }
    // CHECK-NEXT: k-err: boom

    // l: large indirect result + indirect error (exercises both
    // hasIndirectSILResults and the typed-error indirect-return path).
    let l: Result<LargeResult, LargeErr> = await run {
      () async throws(LargeErr) -> LargeResult in
        throw LargeErr(tag: 99, pad: (0, 0, 0, 0))
    }
    switch l {
    case .success(let r): print("l-ok: tag=\(r.tag)")
    case .failure(let e): print("l-err: tag=\(e.tag)")
    }
    // CHECK-NEXT: l-err: tag=99

    // m: NEGATIVE — async non-throws (no indirect-error slot, no marker
    // attached, must work). Regression guard against spurious padding.
    let m = await runIdent { () async -> String in "no-error" }
    print("m-ok: \(m)")
    // CHECK-NEXT: m-ok: no-error

    // n: control-flow-driven captured variable. Cached-context and
    // cached-error must not be conflated: success path doesn't touch
    // ind_error; error path uses ind_error. A swap would corrupt one.
    let capture = Int.random(in: 1...10)
    let nClosure: () async throws(SmallErr) -> String = {
      if capture > 0 { return "ok-\(capture)" } else { throw SmallErr.boom }
    }
    let nResult = await run(nClosure)
    switch nResult {
    case .success(let s): print("n-ok: \(s.hasPrefix("ok-"))")
    case .failure(let err): print("n-err: \(err)")
    }
    // CHECK-NEXT: n-ok: true

    // o: typed throws returning Void —
    // errorSchema.shouldReturnTypedErrorIndirectly may fire even though
    // the native result is Void.
    let oResult: Result<Void, SmallErr> = await run {
      () async throws(SmallErr) -> Void in throw SmallErr.boom
    }
    switch oResult {
    case .success: print("o-ok")
    case .failure(let err): print("o-err: \(err)")
    }
    // CHECK-NEXT: o-err: boom

    // p: multiple indirect results + typed error.
    let pResult: Result<(LargeResult, LargeResult), LargeErr> = await run {
      () async throws(LargeErr) -> (LargeResult, LargeResult) in
        throw LargeErr(tag: 7, pad: (0, 0, 0, 0))
    }
    switch pResult {
    case .success(let pair): print("p-ok: \(pair.0.tag)")
    case .failure(let err): print("p-err: tag=\(err.tag)")
    }
    // CHECK-NEXT: p-err: tag=7

    // q: witness-method x LargeErr — most complex trailing layout:
    // Self+WT trailing the [ind_error, swiftself] pair with indirect
    // typed-error.
    let qResult = await invokeLarge(LargeBoom())
    switch qResult {
    case .success(let s): print("q-ok: \(s)")
    case .failure(let err): print("q-err: tag=\(err.tag)")
    }
    // CHECK-NEXT: q-err: tag=11

    // r: actor cross-isolation — typed-throws async method on a non-Main
    // actor invoked from a nonisolated context, with a large typed error.
    // Exercises hop-thunk lowering + new trailing pair.
    let rResult: Result<String, LargeErr>
    do { rResult = .success(try await LargeActor().bang()) }
    catch { rResult = .failure(error) }
    switch rResult {
    case .success(let s): print("r-ok: \(s)")
    case .failure(let err): print("r-err: tag=\(err.tag)")
    }
    // CHECK-NEXT: r-err: tag=13

    // s: @MainActor + async typed-throws — main-actor hop with a large
    // typed error. Verifies the MainActor isolation thunk doesn't
    // reintroduce a pre-fix layout.
    let sResult: Result<String, LargeErr>
    do { sResult = .success(try await mainLargeErr()) }
    catch { sResult = .failure(error) }
    switch sResult {
    case .success(let s): print("s-ok: \(s)")
    case .failure(let err): print("s-err: tag=\(err.tag)")
    }
    // CHECK-NEXT: s-err: tag=17

    // t: PR 88465 Result.init(catching:) replica. Failure is inferred
    // as `any Error` from the untyped-throws closure literal, which is
    // the path that triggers stdlib/Result.swift on wasi CI 27957 under
    // the SIL band-aid still present on main.
    func asyncThrowing() async throws -> String {
      throw SmallErr.boom
    }
    let t = await MyResult { try await asyncThrowing() }
    switch t {
    case .success(let s): print("t-ok: \(s)")
    case .failure(let e): print("t-err: \(e)")
    }
    // CHECK-NEXT: t-err: boom
  }
}
