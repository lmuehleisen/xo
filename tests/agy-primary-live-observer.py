"""Record a live event before forwarding it to a parking or denying hook."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

payload = json.load(sys.stdin)
with (Path(os.environ["FM_HOME"]) / "state/events.jsonl").open("a") as stream:
    stream.write(json.dumps({"event": sys.argv[1], "time": time.time(),
                             "cwd": os.getcwd(), "payload": payload}) + "\n")

# Silence abstains to native review. A delegated hook retains its input,
# output and exit status, but cannot park or deny before its event is recorded.
if len(sys.argv) > 2:
    sys.exit(subprocess.run(sys.argv[2], shell=True, input=json.dumps(payload),
                            text=True).returncode)
