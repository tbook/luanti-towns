# Re-export the Issue 196 buildings

Run from the Towns mod checkout after saving and closing TownsWorkshop:

```sh
python3 tools/issue196_import/export.py \
  --world "$HOME/Library/Application Support/minetest/worlds/TownsWorkshop"
```

The script takes a read-only SQLite snapshot and captures the three current
Workshop copies at their recorded bounds. A scratch-engine roundtrip checks
every node name and `param2`. It refreshes the farm, shepherd hut, and demo
house schematics; the four stock village assets remain their authored stock
versions. Door state is written to `.lua` sidecars and restored by the normal
placement code. The source world is never modified.
