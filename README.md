# Disguise

How [Causabee](https://causabee.app) hides names before any text leaves your device.

Causabee keeps your matters on your own devices. When it asks a larger AI for help, it first replaces the names, places, addresses, account and phone numbers, and dates of birth in the text with stand-ins like `[Person A]`, and checks once more before the text is sent. The answer comes back with the stand-ins, and Causabee puts the real names back only where they were. This repository is that part of Causabee, so anyone can read how it works and test it.

It finds what to hide in everything that comes in, the same way for every source: mail, screenshots of chats, photos, files and scans, notes, what is said in the chat, and tasks and dates added by hand.

## What is here

- `Sources/Disguise` — the rules that find names, places and numbers (`Detection/`), the list of stand-ins and how a text is disguised and restored (`Pseudonymizer.swift`), and three word lists (`Resources/Names`, CC0, see `LICENCES.txt`).
- `Tests/DisguiseTests` — the tests, on made-up text only. Every name, address and number in them is invented.
- `NameBench` — a separate package that compares two on-device name models on the same made-up cases. It decides nothing in Causabee.

It uses only Apple's own frameworks (Foundation, CryptoKit, NaturalLanguage, Compression, AppKit or UIKit) and needs macOS 15 or iOS 18. Nothing is fetched and nothing is sent.

## Run the tests

```sh
swift test
```

## What it cannot do

It does not find everything. A new name in an unusual spelling, in lowercase, or misread from a picture can go out. What a text is about is sent as it is, so the AI can help with it. Causabee's privacy page says how much it finds, measured on made-up texts it was not written against: [causabee.app/privacy.html](https://causabee.app/privacy.html).

## Problems and ideas

Open an issue in this repository.

## Licence

MIT, see `LICENSE`.
