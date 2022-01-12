#!/usr/bin/env lua5.3

local db     = require("db")
local logger = require("logger")

local from_path, to_path = ...
local from_handle = db.handle(from_path)
local to_handle = db.handle(to_path)

local log = logger.new(print)

to_handle:exec(log:sub("setting up target db"), [[CREATE TABLE IF NOT EXISTS connections(
	"duser" TEXT NOT NULL,
	"tuser" INTEGER NOT NULL,
	"tname" TEXT NOT NULL,
	unique ("duser"),
	unique ("tuser")
)]])
for _, row in pairs(from_handle:exec(log:sub("setting up source db"), [[SELECT * FROM connections]])) do
	to_handle:exec(log:sub("connecting duser $ with tuser $ aka $", row.duser, row.tuser, row.tname), [[INSERT INTO connections ("duser", "tuser", "tname") values (?, ?, ?)]], tostring(row.duser), row.tuser, row.tname)
end
