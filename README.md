# ticket - shell interface to Jiras, Bamboos and Gits

## Overview

This library provides an extendable API to issue tracker webservices,
as well as tools to automate necessary yet repetetive development tasks,
such as:
- setting a branch in an issue and git checkouting it (scripts/dev_start)
- updating and printing issue's fields (scripts/ticket)
- displaying Bamboo plans' progress for a commit (scripts/bamboo)
- triggering a plan (scripts/plan)

and more.

## Prerequisites

This library is written in Perl and has some Perl dependencies.
You can install them with cpanm or see the cpanfile to do it manually.
You also need to have `curl` and `git` available in your $PATH.

## Installation

Just run `install` executable.

## Docker

Instead of installing, you can just `docker pull jbieron/ticket`.
Then all you need to do is to create a config file:
```sh
docker cp jbieron/ticket:/usr/lib/ticket/ticket.conf.example path/to/ticket.conf
```
However, simpler installation comes at the cost of trickier command call.
For example, to run `ticket`, you now have to run the following:
```sh
docker run --rm --workdir /cwd -v `pwd`:/cwd -v path/to/ticket.conf:/usr/lib/ticket/ticket.conf jbieron/ticket ticket
```

## Under the hood

### Authorization

You can encode your password in ticket.config in repo root, in Base64 format, under key `pass64`.
This option takes precedence over other ways of managing your password.

You can also just define `pass: PLAINTEXT_PASS` line in ticket.conf.

When config lacks both `pass` and `pass64`, ticket asks for password the first time you connect to either Bamboo or Jira,
and it stores it in a cookie. Cookie is not stored if you provide wrong password.

## FAQ

- **Q. How do I...?**

A. Most scripts have --help option. Or ask bieron@github.

- **Q. How about...?**
- **Q. Why can't I...?**
- **Q. What the f...?**

A. Feedback welcomed!
