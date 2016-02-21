# ticket - shell interface to Jiras, Bamboos and Gits

## Overview

This library provides an extendable API to issue tracker webservices,
as well as tools to automate necessary yet repetetive development tasks,
such as:
- setting a branch in an issue and git checkouting it (scripts/dev_start)
- updating and printing issue's fields (scripts/ticket)
- getting info on bamboo plans running for given revision

and more.

## Prerequisites

This library is written in Perl and has some Perl dependencies.
You can install them with cpanm or see the cpanfile to do it manually.
You also need to have `curl` and `git` available in your $PATH.

## Installation

Just run `install` executable.

## Authorization

There are two ways for accessing remote services like Jira and Bamboo.
You can either utilize cookies or store your credentials in ~/.ticket/config.
The first way requires you to provide password on demand the first time you connect to both Bamboo or Jira,
and then it stores it in a cookie. Cookie is not stored if you provide wrong password.

For the second way to work you need to have `pass = PLAINTEXT_PASS` line in config.
Note that config approach takes precedence over cookie mechanism.

## FAQ

- **Q. How do I...?**

A. Most scripts have --help option. That has to do for now.

- **Q. How about...?**
- **Q. Why can't I...?**
- **Q. What the f...?**

A. Feedback welcomed at jbieron@gmail.com

## Author

Jan Bieroń, jbieron@gmail.com
