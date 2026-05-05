# Workspace Instructions

- always use caveman skill
- if you hit an error twice check the internet for solns
- if there is a pdf in provided for refrence, first read the table of contents so that you can make navigation easier and content fetching efficient
- Be proactive and automate all viable steps through PowerShell or batch scripts instead of requesting manual user input.
- Prioritize automation via PowerShell and batch scripts.
- Before running a task, if any uncertainty exists, ask only yes/no questions to clarify intent.
- After completing any task, verify that all related processes and outputs are functioning correctly. write blackbox tests or whitebox tests.
- If errors or inconsistencies are detected, automatically log and attempt corrective action.
- Avoid unnecessary or verbose logs. Only output relevant execution results or error summaries.
- When a required command or dependency is missing use PowerShell to verify installation using `powershell Get-Command <tool> -ErrorAction SilentlyContinue` or `powershell where.exe <tool>`
- Before making any change under `driver-project`, validate intended driver change against the PDFs under `pdfs/`: first read the relevant PDF table of contents, then read the relevant section, and record/cite the section used in the work log or final summary.
- driver tests are to be done strictly in the vm named `driver-test` and all credentials are stored in the `.env` file
- the wiki/ has its own repo. i do not want its files in this repo thats why its in this repo's gitignore