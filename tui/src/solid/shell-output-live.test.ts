import { describe, expect, test } from "bun:test"
import { shellCommandsWithOutput } from "./shell-output-live"

describe("shellCommandsWithOutput", () => {
  test("keeps finished commands that captured stdout", () => {
    const listed = shellCommandsWithOutput([
      {
        id: "a",
        command: "echo hi",
        cwd: "/tmp",
        timeout_seconds: 30,
        status: "succeeded",
        output: "hi\n",
        exit_code: 0,
      },
      {
        id: "b",
        command: "pending",
        cwd: "/tmp",
        timeout_seconds: 30,
        status: "pending",
        output: "",
      },
      {
        id: "c",
        command: "empty",
        cwd: "/tmp",
        timeout_seconds: 30,
        status: "succeeded",
        output: "   ",
      },
    ])
    expect(listed.map((item) => item.id)).toEqual(["a"])
  })
})
