import { spawn } from "node:child_process";

export function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    // A child that exits before reading stdin fails this write with EPIPE;
    // that is the child's answer, not this helper's failure, and the close
    // result still stands. Any other stdin error is reported with stderr.
    child.stdin.on("error", (error) => {
      if (error && error.code === "EPIPE") return;
      stderr += `stdin write failed: ${error && error.message ? error.message : error}\n`;
    });
    child.stdin.end(input);
  });
}
