# OpenEMR on OpenShift Developer Sandbox - Quick Start Guide

This guide will get you from zero to a running OpenEMR instance on Red Hat OpenShift Developer Sandbox in minutes.

## Prerequisites Checklist

- [ ] Red Hat OpenShift Developer Sandbox account ([Get free access](https://developers.redhat.com/developer-sandbox))
- [ ] `oc` CLI installed
- [ ] Quay.io account (only if building custom images)
- [ ] `podman` or `docker` installed (only if building custom images)

## Step-by-Step Deployment

### 1. Download the Project

Extract the `openemr-openshift` directory to your local machine.

```bash
cd openemr-openshift
```

### 2. (Optional) Build Custom Container

If you want to build your own container image:

```bash
# Make the build script executable (if not already)
chmod +x build-container.sh

# Build and push to Quay
./build-container.sh

# Or build only (don't push)
./build-container.sh --build-only
```

**Skip this step** if you want to use the pre-built image: `quay.io/ryan_nix/openemr-openshift:7.0.5`

### 3. Login to OpenShift Developer Sandbox

Get your login command from the Developer Sandbox web console:

1. Go to [https://developers.redhat.com/developer-sandbox](https://developers.redhat.com/developer-sandbox)
2. Click "Login" or "Start using your sandbox"
3. Click on your username in top right → "Copy login command"
4. Click "Display Token"
5. Copy the full `oc login` command

```bash
# Paste and run the login command (example):
oc login --token=sha256~xxxxx --server=https://api.sandbox.x8i5.p1.openshiftapps.com:6443
```

### 4. Deploy OpenEMR

The script is pre-configured for Developer Sandbox - no configuration needed!

```bash
# Make the deploy script executable (if not already)
chmod +x deploy-openemr.sh

# Run the deployment
./deploy-openemr.sh
```

The script will:
- Create a new project called `openemr`
- Deploy MariaDB database (5Gi storage)
- Deploy OpenEMR application (10Gi storage)
- Create a secure route with auto-generated URL
- Generate random database passwords
- Save credentials to `openemr-credentials.txt`

**Deployment takes 3-5 minutes**. Watch the progress!

### 6. Access OpenEMR

The deployment script will display the URL at the end:

```
Access URL: https://openemr.apps.ocp.example.com
```

Navigate to this URL in your browser.

### 7. Complete OpenEMR Setup Wizard

1. Click "Proceed to Step 1"
2. Accept the license agreement
3. **Step 2 - Database Setup**: Use the credentials from `openemr-credentials.txt`
   ```
   SQL Server: mariadb
   Database Name: openemr
   Login Name: openemr
   Password: [use password from credentials file]
   ```
4. **Step 3 - OpenEMR Initial User**: Create your admin account
5. Complete the wizard

### 8. First Login

After setup completes:
- Username: [the admin username you created]
- Password: [the admin password you created]

## Verification Commands

```bash
# Check if all pods are running
oc get pods -n openemr

# Should see:
# NAME                       READY   STATUS    RESTARTS   AGE
# mariadb-0                  1/1     Running   0          5m
# openemr-xxxxxxxxxx-xxxxx   1/1     Running   0          3m

# View OpenEMR logs
oc logs -f deployment/openemr -n openemr

# View database logs
oc logs -f statefulset/mariadb -n openemr

# Get the route URL
oc get route openemr -n openemr -o jsonpath='{.spec.host}'
```

## Common Issues

### Issue: Pods stuck in "Pending"
**Cause**: Storage not available

**Solution**:
```bash
# Check PVC status
oc get pvc -n openemr

# If PVC shows "Pending", check storage class
oc describe pvc openemr-documents -n openemr
oc describe pvc mariadb-data -n openemr

# Fix: Update STORAGE_CLASS in deploy-openemr.sh
```

### Issue: "ImagePullBackOff"
**Cause**: Cannot pull container image

**Solution**:
```bash
# Check if image exists
podman pull quay.io/ryan_nix/openemr-openshift:7.0.5

# Or build your own
./build-container.sh

# Update image in deploy-openemr.sh if needed
```

### Issue: Can't access the URL
**Cause**: Route not created or DNS issue

**Solution**:
```bash
# Verify route exists
oc get route openemr -n openemr

# Check route details
oc describe route openemr -n openemr

# Test from command line
curl -I https://openemr.apps.ocp.example.com
```

## Useful Commands

```bash
# Restart OpenEMR pod
oc rollout restart deployment/openemr -n openemr

# View all resources
oc get all -n openemr

# Check storage usage
oc get pvc -n openemr

# Delete everything and start over
oc delete project openemr
./deploy-openemr.sh
```

## Developer Sandbox Notes

- **Projects expire** after 30 days of inactivity - you'll need to redeploy
- **Single replica only** due to ReadWriteOnce storage limitation
- **Storage limits**: 15Gi total (5Gi DB + 10Gi documents)
- **No cluster-admin access**: Can only manage your own projects

## What's Next?

1. **Configure OpenEMR**: Set up facilities, users, and billing codes
2. **Enable HTTPS**: Already configured via OpenShift routes ✓
3. **Setup Backups**: Important - Developer Sandbox projects can expire!
4. **Configure LDAP**: Connect to your organization's directory (if applicable)
5. **Enable Audit Logging**: Configure OpenEMR's audit log for HIPAA compliance

## Important Developer Sandbox Warnings

⚠️ **Project Expiration**: Developer Sandbox projects expire after 30 days of inactivity. Make sure to:
- Export your database regularly
- Back up any patient data
- Document your OpenEMR configuration

⚠️ **Not for Production**: Developer Sandbox is free for development/testing only. For production use:
- Deploy on a paid OpenShift cluster
- Use ReadWriteMany storage for high availability
- Implement proper backup and disaster recovery
- Enable full HIPAA compliance measures

## Getting Help

- **OpenEMR Documentation**: https://www.open-emr.org/wiki/
- **OpenShift Documentation**: https://docs.openshift.com/
- **This Project's README**: See `README.md` for detailed information

## Security Reminder

⚠️ **Before using with real patient data:**
1. Enable encryption at rest for storage
2. Implement network policies
3. Configure proper backup procedures
4. Review HIPAA compliance requirements
5. Enable audit logging
6. Implement proper access controls

---

**Estimated time to complete**: 15-20 minutes (including setup wizard)
