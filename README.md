# wireframe-mode

Keyboard-first wireframe prototyping inside GNU Emacs.

`wireframe-mode` is a lightweight “Wireframing for developers” focused on low-fidelity structure, fast iteration, and DSL-driven UI thinking.

<img width="1136" height="769" alt="example_image_01" src="https://github.com/user-attachments/assets/4199ff3f-d49e-4d93-9abe-eba03ef0bf8e" />

<img width="1340" height="686" alt="example_image_02" src="https://github.com/user-attachments/assets/76288a3e-00a8-414e-88c9-3f42cce5c716" />

## Features

- Lisp DSL for screen composition
- Internal parser + HTML/CSS renderer
- Live preview in Emacs split (`eww`) with right-pane layout
- Save-to-refresh workflow
- Structural editing commands (clone, wrap, unwrap, promote, demote)
- Spacing controls (`:padding`, `:margin`, `:gap`) with numeric and bump actions
- Linting for unknown components/attributes
- HTML export + optional JSX export
- Command palette (`C-c w`) for fast action access

## Quick Start

1. Install package:

```elisp
(add-to-list 'load-path "/path/to/wire_proto")
(require 'wireframe-mode)
```

2. Create a file like `home.wire` and insert DSL:

```lisp
(screen home
  (header "Logo" "Menu")
  (section :padding 20 :bg "#ffffff"
    (title "Hero Title")
    (paragraph "Short intro text" :color "#475569")
    (container :direction horizontal :gap 12
      (button "Get Started" :bg "#dbeafe" :border "1px solid #60a5fa")
      (button "Learn More")))
  (section
    (title "Feature Cards")
    (card-list 3))
  (section
    (title "Media")
    (image-placeholder 420 180)))
```

3. Open split preview:

- `C-c C-s` (`M-x wireframe-preview-split`)

4. Save and iterate:

- `C-x C-s` refreshes preview live

5. Export:

- `C-c C-e` for HTML

## DSL Reference

### Root

- `(screen NAME ...children)`

### Components

- `(header "Left" "Right")`
- `(section ...children)`
- `(container :direction horizontal|vertical ...children)`
- `(horizontal ...children)`
- `(vertical ...children)`
- `(title "Text")`
- `(paragraph "Text")`
- `(text "Text")` (alias of paragraph)
- `(button "Label")`
- `(image-placeholder WIDTH HEIGHT)`
- `(card-list N)`

### Common attributes

- `:padding NUMBER`
- `:margin NUMBER`
- `:gap NUMBER`
- `:bg \"#hex|css-color\"`
- `:color \"#hex|css-color\"`
- `:border \"1px solid #xxx\"`
- `:radius NUMBER`
- `:font-size NUMBER`
- `:font-weight 400|500|600|700`

Example:

```lisp
(section :padding 20 :bg "#f8fbff" :radius 12
  (title "Pricing" :color "#1e293b")
  (button "Start Trial" :bg "#dbeafe" :border "1px solid #60a5fa"))
```

## Keybindings

### Core

- `C-c C-s` preview in Emacs split (right side)
- `C-c C-v` preview (auto backend)
- `C-c C-e` export HTML
- `C-c C-j` export JSX

### Editing

- `C-c C-a` add component template
- `C-c C-k` clone component
- `C-c C-d` delete component
- `M-<up>` move component up
- `M-<down>` move component down
- `C-c C-w` wrap in vertical container
- `C-c C-u` unwrap container
- `C-c <left>` promote component
- `C-c <right>` demote component

### Spacing

- `C-c C-p` set `:padding`
- `C-c C-m` set `:margin`
- `C-c C-g` set `:gap`
- `C-c +` increase `:padding` by 4
- `C-c -` decrease `:padding` by 4

### Tooling

- `C-c C-l` lint buffer
- `C-c w` command palette

## Command Palette

Run `C-c w` and choose actions such as:

- Add/clone/delete
- Wrap/unwrap
- Promote/demote
- Lint
- Preview split
- Export HTML

## Preview Behavior

- Preferred: `eww` side split (right panel)
- Optional: xwidget if available
- Fallback: external browser
- Last fallback: plain HTML buffer (`*wireframe-preview-html*`)

Important: `eww` is Emacs built-in browser and is great for structure/layout iteration, but it does not render modern CSS fully. For accurate color and visual styling, use `C-c C-v` (browser/xwidget path).


### xwidget unavailable

No issue. Split preview uses `eww` and does not require xwidget.

## Support / Donate

If this project helps you, you can support development:

- TRC20: `TR7s5Edfdh9wkYw4xEyk7uAVyV7Qm9yA1X`
- ERC20: `0xe1c6864fdddcef5b5c63b2ea62af91395b569e36`
- BTC: `1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7`
