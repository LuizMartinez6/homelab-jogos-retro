BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    . (Join-Path $Arquivos 'correcoes.ps1')
    $Ferramenta = Join-Path $PSScriptRoot '..\..\ferramentas\correcao-eden.ps1'
    $Id = '0100606026F12000'

    function New-Base {
        $base = Join-Path $TestDrive "base-$([guid]::NewGuid())"
        New-Item "$base\Emuladores\Eden\user" -ItemType Directory -Force | Out-Null
        $base
    }

    function New-Lista($base, $itens) {
        $arq = Join-Path $base 'correcoes.json'
        [IO.File]::WriteAllText($arq, (ConvertTo-Json @($itens) -Depth 5))
        $arq
    }

    $Correcao = [ordered]@{ id = 'ff-nvdec'; emulador = 'Eden'; titleId = $Id.ToLower()
        valores = [ordered]@{ Renderer = [ordered]@{ nvdec_emulation = '1'; use_asynchronous_gpu_emulation = 'false' } } }
}

Describe 'Invoke-Correcoes' {
    It 'grava a configuracao do jogo no Eden com use_global=false e marca como aplicada' {
        $base = New-Base
        Invoke-Correcoes $base (New-Lista $base $Correcao) | Should -Be 'ff-nvdec'
        $ini = [IO.File]::ReadAllLines("$base\Emuladores\Eden\user\config\custom\$Id.ini")
        $ini | Should -Be @('[Renderer]', 'nvdec_emulation\use_global=false', 'nvdec_emulation\default=false', 'nvdec_emulation=1',
            'use_asynchronous_gpu_emulation\use_global=false', 'use_asynchronous_gpu_emulation\default=false', 'use_asynchronous_gpu_emulation=false')
        [IO.File]::ReadAllLines("$base\correcoes-aplicadas.txt") | Should -Be @('ff-nvdec')
    }

    It 'troca so as chaves da correcao num ini que ja existe' {
        $base = New-Base
        Write-Utf8 "$base\Emuladores\Eden\user\config\custom\$Id.ini" "[Cpu]`r`ncpu_accuracy=1`r`n`r`n[Renderer]`r`nnvdec_emulation\use_global=true`r`nnvdec_emulation=2`r`nresolution_setup=3"
        Invoke-Correcoes $base (New-Lista $base $Correcao) | Out-Null
        $ini = [IO.File]::ReadAllLines("$base\Emuladores\Eden\user\config\custom\$Id.ini")
        $ini | Should -Contain 'cpu_accuracy=1'
        $ini | Should -Contain 'resolution_setup=3'
        $ini | Should -Contain 'nvdec_emulation\use_global=false'
        $ini | Should -Contain 'nvdec_emulation=1'
        $ini | Should -Not -Contain 'nvdec_emulation=2'
    }

    It 'aplica uma vez so: se o amigo desfizer, fica como ele deixou' {
        $base = New-Base
        $lista = New-Lista $base $Correcao
        Invoke-Correcoes $base $lista | Out-Null
        $ini = "$base\Emuladores\Eden\user\config\custom\$Id.ini"
        Write-Utf8 $ini "[Renderer]`r`nnvdec_emulation\use_global=true"
        Invoke-Correcoes $base $lista | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($ini) | Should -Not -Match 'nvdec_emulation=1'
    }

    It 'sem Eden, sem lista ou com Title ID invalido nao faz nada' {
        $base = Join-Path $TestDrive 'sem-eden'
        New-Item $base -ItemType Directory -Force | Out-Null
        Invoke-Correcoes $base (New-Lista $base $Correcao) | Should -BeNullOrEmpty
        Test-Path "$base\correcoes-aplicadas.txt" | Should -BeFalse -Because 'fica para quando o Eden for instalado'
        Invoke-Correcoes (New-Base) (Join-Path $TestDrive 'nao-existe.json') | Should -BeNullOrEmpty
        $base = New-Base
        Invoke-Correcoes $base (New-Lista $base ([ordered]@{ id = 'x'; emulador = 'Eden'; titleId = '..\..\x'; valores = @{} })) | Should -BeNullOrEmpty
    }
}

Describe 'correcoes.json publicado' {
    It 'cada correcao tem id unico, Title ID valido e valores' {
        $lista = @([IO.File]::ReadAllText((Join-Path $Arquivos 'correcoes.json')) | ConvertFrom-Json)
        $lista.Count | Should -BeGreaterThan 0
        @($lista.id | Sort-Object -Unique).Count | Should -Be $lista.Count
        foreach ($c in $lista) {
            $c.emulador | Should -Be 'Eden'
            $c.titleId | Should -Match '^[0-9A-F]{16}$'
            @($c.valores.PSObject.Properties).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'correcao-eden.ps1 (ferramenta do dono)' {
    It 'devolve a mesma correcao que o Invoke-Correcoes gravou' {
        $base = New-Base
        Invoke-Correcoes $base (New-Lista $base $Correcao) | Out-Null
        $saida = (& $Ferramenta $Id -Id 'ff-nvdec' -Eden "$base\Emuladores\Eden") -join "`n" | ConvertFrom-Json
        $saida.titleId | Should -Be $Id
        $saida.valores.Renderer.nvdec_emulation | Should -Be '1'
        $saida.valores.Renderer.use_asynchronous_gpu_emulation | Should -Be 'false'
    }

    It 'recusa jogo sem nada proprio' {
        $base = New-Base
        Write-Utf8 "$base\Emuladores\Eden\user\config\custom\$Id.ini" "[Renderer]`r`nnvdec_emulation\use_global=true`r`nnvdec_emulation=2"
        { & $Ferramenta $Id -Id 'x' -Eden "$base\Emuladores\Eden" } | Should -Throw '*nada diferente*'
    }
}
