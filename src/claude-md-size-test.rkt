#lang racket/base

;; CLAUDE.md is read at the start of every agent session, so every byte competes with
;; every rule for the agent's attention. It was cut from 58 KB to 12 KB on 2026-11-19 by
;; moving the description of each subsystem to docs/agents/. This test stops it growing
;; past the limit unnoticed: detail that matters only for one kind of work belongs in
;; docs/agents/, behind a line in CLAUDE.md that says when to read it.

(require rackunit
         racket/runtime-path)

(define-runtime-path claude-md "../CLAUDE.md")

(define limit-bytes 16000)

(let ([size (file-size claude-md)])
  (check-true
   (<= size limit-bytes)
   (format "CLAUDE.md is ~a bytes, over the limit of ~a. Move detail that applies only to one kind of work into docs/agents/, and leave a line in CLAUDE.md that says when to read it (\"Before changing X, read docs/agents/x.md\"). Raise the limit only if the new text must be read in every session."
           size limit-bytes)))
