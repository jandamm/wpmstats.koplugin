# WPM Statistics for KOReader

## Prepare books
You can configure Calibre to add two custom rows: `#pages` and `#words`. (Count Pages plugin)

### epub
The counts will be fetched from the metadata.
Alternatively you can put it in the name: `filename abc P(10) W(100).pdf`

### pdfs
For pdfs the word count needs to be in the name: `filename abc W(100).pdf`
The page count will be fetched automatically.

## Setup

- Enable the statistics plugin (builtin)
- Install this plugin
- Run `Refresh Pages and Word count`

It's only necessary to cache the books once. New books will automatically be added when they are being read.
