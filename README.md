# Disguise

How [Causabee](https://causabee.app) hides names before any text leaves your device.

Causabee keeps your matters on your own devices. When it asks a larger AI for help, it first replaces the names, places, addresses, account and phone numbers, and dates of birth in the text with stand-ins like `[Person A]`, and checks once more before the text is sent. The answer comes back with the stand-ins, and Causabee puts the real names back only where they were. This repository is that part of Causabee, so anyone can read how it works and test it.

It finds what to hide in everything that comes in, the same way for every source: mail, screenshots of chats, photos, files and scans, notes, what is said in the chat, and tasks and dates added by hand.

## What is here

- `Sources/Disguise` — the rules that find names, places and numbers (`Detection/`), the list of stand-ins and how a text is disguised (`Pseudonymizer.swift`), the record of one send that its answer is put back from (`SendRecord.swift`), and three word lists (`Resources/Names`, CC0, see `LICENCES.txt`).
- `Tests/DisguiseTests` — the tests, on made-up text only. Every name, address and number in them is invented.
- `NameBench` — a separate package that compares two on-device name models on the same made-up cases. It decides nothing in Causabee.

It uses only Apple's own frameworks (Foundation, CryptoKit, NaturalLanguage, Compression, AppKit or UIKit) and needs macOS 15 or iOS 18. It fetches nothing and sends nothing itself. Before it looks for names, it asks the system for Apple's own name model; if the model is missing, the system may download it from Apple once. No text goes with that request.

## What 1.1.4 fixes

- **Ordinary words written small are no names.** The last look before a send hid every word the dictionary did not know as written, so a chat or a note typed in a hurry lost its ask: „kanst du morgn die schlüssel abhohlen“ went out as four stand-ins, and „Der umzug ist für dne …“ came back with two people in it. Now a word written small stays as written when the dictionary knows it with a capital („schlüssel“, „umzug“) and nothing in the text reads it as a name or a place, or when it is one letter off a word written small („morgn“, „kanst“, „abhohlen“, „dne“).
- **The price, chosen openly.** Before, every word written small that the dictionary did not know was hidden, names and ordinary words alike. That was safer for names, and it made hurried asks unreadable. 1.1.4 chooses readable asks: **a name written small that no name list holds, or a misspelt one, now goes out as written when it is one letter off an ordinary word** — „hallo sevn“ („sehn“, „sein“), „ich treffe marle morgen“ („marke“). The same name written with a capital is judged as before.
- **What still hides a name written small:**
  - the name lists hold it („julian“, „müller“), or a list cannot be read;
  - the tagger reads it as a person, a place or a company once it has a capital („in bremen“; only for a word the dictionary knows with a capital);
  - it looks like a street („lindenstraße 4“);
  - no dictionary knows it and none offers a word one letter off it („hollenbach“);
  - it stands right after a title, with only a space between („frau“, „herr“, „dr.“, „prof.“, „mrs“, „mr“ and the other titles): there a word is never excused, whatever it is one letter off („herr sevn“ is hidden);
  - it stands right after, with only a space between, one of these words: bei, mit, von, für, zu, frag, frage, fragt, sag, sage, sagt, ruf, rufe, schreib, schreibe, grüß, grüße, hat, hast, meint, ask, tell, call, ring, text. Even there, a word one letter off a small word goes out („bei sevn“, off „sein“, as „für dne“ is „für den“).
- **What is no guard:** „an“, „und“, „hallo“ and other greetings, a quote mark, a colon, „@“, a chat line's „[12:01] name:“, or a stand-in before the word. A name written small in those places, one letter off a word and on no list, goes out.
- The tests pin these cases (`OrdinaryWordsWrittenSmallTests`), so changing them is a choice, not an accident. The rules that find names are the same.

## What 1.1.3 fixes

- **Familie and Fräulein anchor a name.** Like a title, they keep the word after them a name: „Familie Herren“, „Fräulein Damen“, „Familie Sehr“ are hidden as 1.1.0 hid them, and „Familie“ stays readable in front of the stand-in. The golden test gives the same bytes as 1.1.0.

## What 1.1.2 fixes

- **A title keeps the name.** 1.1.1 let a few rare surnames out that 1.1.0 hid: after a title the word is a name, even one that is a greeting or a word for everyone — „Herr Sehr“, „Herr Herren“, „Frau Damen“ are hidden again; „Herren“ and „Damen“ in front of names work as a title („die Herren Weber und Kurz“). „Sehr geehrte Damen und Herren“ still has no one in it.
- Still open: a surname written first, „Herren, Thomas“, reads like the end of the greeting, and „Herren“ goes as written there.
- Nothing else changes: the golden test gives the same bytes as 1.1.0.

## What 1.1.1 fixes

- **A greeting to everyone is no one.** „Sehr geehrte Damen und Herren“ and „Ladies and Gentlemen“ have no person in them: „Damen“, „Herren“, „Ladies“ and „Gentlemen“ are never a name alone, nor part of one, and „Sehr geehrte“ read in an English text is a greeting too. A name after them is still found („Herr Quellbrunn“).
- **„Büro“ is no one alone.** It says what a place of work is, like „Kanzlei“ or „Praxis“: alone it stays as written, and with a name the name is found. An id of a letter or two and digits written before a word („X1 Büro“) is no part of a name.
- Nothing else changes: the golden test gives the same bytes as 1.1.0.

## What 1.1.0 adds

- **One person, one stand-in.** A person, a company or a place written several ways is one row of the list with one stand-in: „Herrn Patrick Schüßler“, „SCHÜSSLER Patrick“, „Patrick Schuessler“ and „Schüßler, Patrick“ all go out as `[Person A]`, with a title kept in front as written (`Herrn [Person A]`). The other ways are kept behind the row, and one switch covers them all.
- **Apart when unsure.** When it is not clear that two names are one person, they stay two: a first name or a surname two known people share gets a stand-in of its own, an initial („P. Schüßler“) is a row of its own, and a shorter company name is not joined to a longer one. Names are compared with ß and ss, umlauts, accents, capitals and quote marks set aside only to join them, never to find a word in a text.
- **French titles.** Monsieur, Madame, Mademoiselle, Mme and Mlle are read as titles for the list, like Herr and Frau, and stay in front of the stand-in. The rules that find names are unchanged.
- **The way back is the send's own record.** While a text is disguised, `SendRecord` notes what each stand-in replaced in it, word for word. The answer is put back from that record only: a stand-in comes back as the words that were sent, never as a fuller name or another person's surname, and one the send did not carry keeps its brackets. The record lives in memory with its send and cannot be written anywhere (it is not `Codable`).
- **The list from before.** The list's JSON goes to version 7 and gains three optional keys: `joined` on the list, `form_of` on a way of writing (the row it belongs to), and `ways` on a switch that covers every way of writing a row. An older version ignores them, drops them when it writes its own file, and keeps hiding every name it hid. A list from 1.0.1 is joined once when it is read, and checked word by word: nothing it hid goes out as written afterwards, except the five French titles in front of a name.

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
