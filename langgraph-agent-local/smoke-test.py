import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
from agent import graph  # noqa: E402
print("Graph loaded, nodes:", list(graph.nodes))
print("Tools attached:", len(graph.get_graph().nodes.get("tools").data.tools_by_name) if "tools" in graph.get_graph().nodes else "n/a")
