#!/usr/bin/env python3
"""Fill the demo Kanban board from demo-script.json with the hermes CLI.

Each task is created ready, then moved: "running" claims it (nothing
dispatches on the demo, so the claim holds), "blocked" blocks it with its
reason, "done" completes it with its result. A task with "parent" waits in
To do behind the task whose "id" matches.

Usage: seed_board.py SCRIPT.json HERMES
"""

import json
import subprocess
import sys


def main(script_path, hermes):
    def run(*args):
        return subprocess.run([hermes, "kanban", *args], check=True, capture_output=True, text=True).stdout

    ids = {}
    for task in json.load(open(script_path, encoding="utf-8")).get("kanban", []):
        args = ["create", task["title"], "--json"]
        if task.get("body"):
            args += ["--body", task["body"]]
        if task.get("assignee"):
            args += ["--assignee", task["assignee"]]
        if task.get("parent"):
            args += ["--parent", ids[task["parent"]]]
        task_id = json.loads(run(*args))["id"]
        if task.get("id"):
            ids[task["id"]] = task_id
        status = task.get("status")
        if status == "running":
            run("claim", "--ttl", "86400", task_id)
        elif status == "blocked":
            run("block", task_id, task.get("reason", "Waiting"))
        elif status == "done":
            run("complete", task_id, "--result", task.get("result", "Done."))
        print(f"board: {task['title']} ({status or 'todo'})")


if __name__ == "__main__":
    main(*sys.argv[1:3])
