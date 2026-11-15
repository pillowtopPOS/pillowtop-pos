# Tester script: Units page (branch unit-s1)

Setup facts (already done by Zach before you start): three demo units exist for a product called "DEMO Unit ID Mattress" (sku DEMO-UNIT-1) at Denver Main Warehouse. Unit numbers are 1, 2 and 3. Sign in as an OWNER or ADMIN first. Report PASS or FAIL for each step with what you actually saw. Screenshot every FAIL.

## A. Reaching the page
A1. In the left sidebar, find "Units" next to Inventory. Click it. PASS: the Units page opens at /units, title "Units", one number box with the cursor already in it.

## B. Lookup
B1. Type 1, press Enter. PASS: a card shows #1, badge "In stock", product "DEMO Unit ID Mattress (DEMO-UNIT-1)", location "Denver Main Warehouse", condition Prime, no customer line. History shows one line: "Received into stock at Denver Main Warehouse" with a date and time. No "No history yet" flash before it.
B2. Type 2, Enter. PASS: badge "Held for a customer". A Customer line shows "DEMO Customer" as a link. History has two lines: received, then "In stock to Held for a customer at Denver Main Warehouse".
B3. Click the Customer link. PASS: the board opens on the DEMO Customer journey (it is OK if the journey panel looks sparse). Use the browser Back button to return to /units.
B4. Type 3, Enter. PASS: badge "Missing", history shows "In stock to Missing".
B5. Scanner behavior: the number box should be highlighted/selected after a lookup. Without clicking, type 1 then Enter, then type 2 then Enter. PASS: the second lookup is for #2 (not 12 and not 12 appended). Repeat typing 3 Enter. PASS: #3.
B6. Type 999, Enter. PASS: "No unit with number 999." and the box is selected.
B7. Try to type letters and a 20 digit number. PASS: letters are ignored; the box stops at 15 digits.
B8. Press Enter with an empty box. PASS: nothing happens, no error.
B9. Type 1 then Enter twice very fast. PASS: no flicker of wrong data; the final card is #1.

## C. Discrepancies (owner or admin only)
C1. Find the "Discrepancies" section below the lookup. Click it. PASS: opens, shows the explanation line and a table with exactly ONE row: DEMO Unit ID Mattress (DEMO-UNIT-1), Denver Main Warehouse, Prime, Units say 2, Stock says 3, Difference -1 (amber), Reserved 1/1 (NOT amber).
C2. Click Discrepancies again to close, then again to open. PASS: still the same row, no crash.

## D. Permissions
D1. Sign in as a plain employee-role user (not owner/admin). If no such user exists, skip and say so. PASS: Units lookup works, but NO Discrepancies section appears at all.

## E. Console
E1. With the browser console open during A to C, report any red errors (copy the text).

Do not change any data. Do not run any SQL.
