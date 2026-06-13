# parent-pipeline
## The Assembly Line

Every project goes through 5 checkpoints before it reaches the public:

📥 Code arrives (developer pushes code)
↓
🔍 Checkpoint 1 - SECRET SCAN
Security guard checks if any passwords or
API keys were accidentally left in the code
↓
🏗️ Checkpoint 2 - BUILD
The code is packaged into a Docker image
and stored in our private warehouse (Harbor)
↓
🛡️ Checkpoint 3 - SECURITY SCAN
Two independent inspectors check the
packaged image for known security weaknesses
↓
✅ Checkpoint 4 - INTERNAL APPROVAL (Manual)
A team member reviews the inspection reports
and approves the image for promotion
↓
🚀 Checkpoint 5 - PUBLISH (Manual)
The approved image is published to the
public registry for end users to access

## Tools Used

| Checkpoint | Tool | Job |
|------------|------|-----|
| Secret Scan | TruffleHog | Finds accidentally committed passwords/keys |
| Build | Kaniko | Packages code into a Docker image |
| Security Scan | Grype | Checks image for known vulnerabilities |
| Security Scan | Trivy | Double checks vulnerabilities + secrets in image |
| Promote/Publish | Skopeo | Moves approved image between registries |
