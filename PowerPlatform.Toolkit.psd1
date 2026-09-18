@{
    RootModule        = 'PowerPlatform.Toolkit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7a1a6d0-8c1e-4f2a-9b3e-6a2f0c1d4e5f'
    Author            = 'Claude'
    CompanyName       = 'Unknown'
    Copyright         = '(c) 2026'
    Description       = 'Injection-hardened PowerShell 7 toolkit for the Dataverse Web API underlying Power Apps (model-driven apps) and Power Pages (websites): safe OData filter building, a hardened REST wrapper, and generic + convenience record functions.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Test-PowerPlatformGuid'
        'ConvertTo-SafeODataLiteral'
        'New-PowerPlatformFilter'
        'Connect-PowerPlatformSession'
        'Disconnect-PowerPlatformSession'
        'Invoke-PowerPlatformApiRequest'
        'Get-PowerPlatformRecord'
        'Set-PowerPlatformRecordField'
        'Get-PowerPagesWebsite'
        'Get-PowerPlatformAppModule'
        'Export-PowerPlatformInventory'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('PowerPlatform', 'PowerApps', 'PowerPages', 'Dataverse', 'PowerShell7')
            ProjectUri = ''
        }
    }
}
