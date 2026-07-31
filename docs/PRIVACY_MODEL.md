# Privacy Model

## Data Flow

```
User Action → MacSteam → Process Launch
                            ↓
                    External Application
```

## Data at Rest

- **Configuration**: Stored in `~/Library/Application Support/MacSteam/settings/`
- **Logs**: Stored in `~/Library/Application Support/MacSteam/logs/`
- **State**: Stored in `~/Library/Application Support/MacSteam/state/`

No data is written outside the application support directory except by
external processes (Steam, CrossOver, games), which have their own storage.

## Data in Transit

MacSteam does not transmit data over any network interface.

External processes (Steam, CrossOver, games) may perform their own network
communication. This is outside MacSteam's control and scope.

## Data Collection

MacSteam itself collects no telemetry, analytics, or usage data.

## Data Retention

Logs are retained until the user deletes them. MacSteam does not implement
automatic log rotation in the initial release.

## User Control

Users can:

- View logs from the Diagnostics screen
- Delete logs by removing `~/Library/Application Support/MacSteam/logs/`
- Reset state by removing `~/Library/Application Support/MacSteam/`

## Compliance

- **GDPR**: No personal data is collected or processed.
- **CCPA**: No personal data is collected or sold.
- **COPPA**: Not directed at children under 13.
