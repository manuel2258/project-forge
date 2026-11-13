# forge · phone UI kit

A click-through of the core loop, built only from `components/`:

1. Queue item (approval): sentence, ContextCard, changeset summary. The queue never approves; "Review the changeset ›" opens it.
2. Changes page: TopBar + DecisionRow pinned under it, files below, BottomStrip of views.
3. Approve drops a DropPanel with the consequence, a note and Reject.
4. Approve v1 shows a Toast and moves to the next queue item. The end of the queue is a definite state.

All screens of the product, including desktop, are in `Final Design.dc.html` at the project root.
