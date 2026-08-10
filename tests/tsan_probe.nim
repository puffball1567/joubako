import std/[atomics, locks, os, strutils]
import joubako

const WorkerCount = 4

type
  ThreadPayload {.proto3.} = object
    worker {.fieldNumber: 1, pint.}: uint32
    sequence {.fieldNumber: 2, pint.}: uint32
    text {.fieldNumber: 3.}: string

  SharedState = object
    completed: int
    operations: Atomic[int]
    lock: Lock

  WorkerInput = object
    worker: int
    iterations: int
    shared: ptr SharedState

proc exercise(input: WorkerInput) {.thread.} =
  for index in 0 ..< input.iterations:
    let value = ThreadPayload(
      worker: input.worker.uint32,
      sequence: index.uint32,
      text: "thread-" & $input.worker & "-" & $index
    )
    let cbor = tryEncodeCborPayload(value)
    doAssert cbor.isOk
    doAssert decodeCborPayload(cbor.value, ThreadPayload) == value

    let protobuf = tryEncodeProtobufPayload(value)
    doAssert protobuf.isOk
    doAssert decodeProtobufPayload(protobuf.value, ThreadPayload) == value

    let frame = encodeGrpcFrame(value)
    doAssert decodeGrpcFrames(frame, ThreadPayload) == @[value]

    let path = withQuery("/thread", [
      (name: "worker", value: $input.worker),
      (name: "sequence", value: $index)
    ])
    doAssert "worker=" & $input.worker in path
    discard input.shared.operations.fetchAdd(1, moRelaxed)

  acquire(input.shared.lock)
  inc input.shared.completed
  release(input.shared.lock)

proc main() =
  let iterations = getEnv("JOUBAKO_THREAD_ITERATIONS", "1000").parseInt
  doAssert iterations > 0

  # Initialize generic serializers before workers begin so the probe targets
  # concurrent calls rather than one-time module initialization order.
  let warmup = ThreadPayload(text: "warmup")
  discard encodeCborPayload(warmup)
  discard encodeProtobufPayload(warmup)
  discard encodeGrpcFrame(warmup)

  var shared: SharedState
  initLock(shared.lock)
  defer: deinitLock(shared.lock)
  var workers: array[WorkerCount, Thread[WorkerInput]]
  for index in 0 ..< WorkerCount:
    createThread(workers[index], exercise, WorkerInput(
      worker: index,
      iterations: iterations,
      shared: shared.addr
    ))
  joinThreads(workers)
  doAssert shared.completed == WorkerCount
  doAssert shared.operations.load(moRelaxed) == WorkerCount * iterations

main()
