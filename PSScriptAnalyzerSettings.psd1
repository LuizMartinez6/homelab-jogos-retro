# Regras do PSScriptAnalyzer para o projeto. Uso: Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Os scripts sao interativos: a interface le a saida colorida do setup.ps1.
        'PSAvoidUsingWriteHost'
        # Funcoes internas de script, nao cmdlets publicados: -WhatIf nao faz sentido.
        'PSUseShouldProcessForStateChangingFunctions'
        # Nomes em portugues (Get-Plataformas, Sync-JogosInstalados) sao de proposito.
        'PSUseSingularNouns'
        # Catch vazio e de proposito: launcher e atualizador nunca podem impedir o Playnite de abrir.
        'PSAvoidUsingEmptyCatchBlock'
        # Handlers do WPF ($s, $e) e eventos do Playnite exigem a assinatura completa.
        'PSReviewUnusedParameter'
    )
    Rules        = @{
        # O instalador roda no Windows PowerShell 5.1 do PC dos amigos.
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
    }
}
