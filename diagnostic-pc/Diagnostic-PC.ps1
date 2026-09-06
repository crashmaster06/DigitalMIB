#Requires -Version 5.1
<#
Diagnostic-PC.ps1
Script de diagnostic et maintenance PC - menu interactif en console.
Compatible Windows 10/11, PowerShell natif uniquement (aucun module a installer).
#>

$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Global:RapportResultats = @()
$Global:ModeAutomatique  = $false

# --- Fonctions communes ---------------------------------------------------

function Test-EstAdmin {
    $identite  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identite)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ecrire-Ligne {
    param(
        [ValidateSet('OK', 'ATTENTION', 'CRITIQUE', 'INFO')][string]$Type,
        [string]$Message
    )
    $couleur = switch ($Type) {
        'OK'        { 'Green' }
        'ATTENTION' { 'Yellow' }
        'CRITIQUE'  { 'Red' }
        'INFO'      { 'Cyan' }
    }
    Write-Host "  [$Type] $Message" -ForegroundColor $couleur
    return "[$Type] $Message"
}

function Get-PireStatut {
    param([string[]]$Statuts)
    if ($Statuts -contains 'CRITIQUE')  { return 'CRITIQUE' }
    if ($Statuts -contains 'ATTENTION') { return 'ATTENTION' }
    return 'OK'
}

function Ajouter-Resultat {
    param([string]$Titre, [string]$Statut, [string[]]$Lignes)
    $Global:RapportResultats += [PSCustomObject]@{
        Titre  = $Titre
        Statut = $Statut
        Lignes = $Lignes
    }
}

# --- Option 1 : Espace disque ---------------------------------------------

function Analyse-EspaceDisque {
    Write-Host ""
    Write-Host "=== 1. ESPACE DISQUE ===" -ForegroundColor White
    $lignes = @()
    $statuts = @()

    try {
        $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }
        foreach ($vol in $volumes) {
            $totalGo = [math]::Round($vol.Size / 1GB, 1)
            $libreGo = [math]::Round($vol.SizeRemaining / 1GB, 1)
            $utiliseGo = [math]::Round($totalGo - $libreGo, 1)
            $pourcentLibre = if ($totalGo -gt 0) { [math]::Round(($libreGo / $totalGo) * 100, 0) } else { 0 }

            $type = if ($pourcentLibre -lt 10) { 'CRITIQUE' } elseif ($pourcentLibre -lt 20) { 'ATTENTION' } else { 'OK' }
            $msg = "Disque $($vol.DriveLetter): $utiliseGo Go utilises / $totalGo Go ($libreGo Go libres, $pourcentLibre% libre)"
            $lignes += Ecrire-Ligne -Type $type -Message $msg
            $statuts += $type
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'CRITIQUE' -Message "Impossible de lire les volumes : $($_.Exception.Message)"
        $statuts += 'CRITIQUE'
    }

    try {
        Write-Host "  Analyse des dossiers volumineux dans votre profil utilisateur (peut prendre quelques secondes)..." -ForegroundColor Gray
        $racine = $env:USERPROFILE
        $dossiers = Get-ChildItem -Path $racine -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $taille = (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
                [PSCustomObject]@{ Nom = $_.FullName; TailleGo = [math]::Round(($taille / 1GB), 2) }
            } | Sort-Object TailleGo -Descending | Select-Object -First 10

        $lignes += "--- Top 10 dossiers les plus volumineux (dans $racine) ---"
        foreach ($d in $dossiers) {
            $l = "$($d.Nom) : $($d.TailleGo) Go"
            Write-Host "  $l" -ForegroundColor Gray
            $lignes += $l
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Analyse des dossiers volumineux impossible : $($_.Exception.Message)"
    }

    try {
        $cheminsTemp = @($env:TEMP, "$env:WINDIR\Temp", "$env:LOCALAPPDATA\Temp")
        $tailleTotale = 0
        foreach ($chemin in $cheminsTemp) {
            if (Test-Path $chemin) {
                $tailleTotale += (Get-ChildItem -Path $chemin -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
            }
        }
        $tailleTempGo = [math]::Round($tailleTotale / 1GB, 2)
        $type = if ($tailleTempGo -gt 5) { 'ATTENTION' } else { 'OK' }
        $lignes += Ecrire-Ligne -Type $type -Message "Fichiers temporaires/cache detectes : $tailleTempGo Go (nettoyables sans risque)"
        $statuts += $type
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Calcul des fichiers temporaires impossible : $($_.Exception.Message)"
    }

    Ajouter-Resultat -Titre "1. Espace disque" -Statut (Get-PireStatut -Statuts $statuts) -Lignes $lignes
}

# --- Option 2 : Sante disque dur / SSD ------------------------------------

function Analyse-SanteDisque {
    Write-Host ""
    Write-Host "=== 2. SANTE DISQUE DUR / SSD ===" -ForegroundColor White
    $lignes = @()
    $statuts = @()

    if (-not (Test-EstAdmin)) {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Cette analyse necessite les droits administrateur. Relancez le script en 'Executer en tant qu'administrateur' pour un resultat complet."
        Ajouter-Resultat -Titre "2. Sante disque dur / SSD" -Statut 'ATTENTION' -Lignes $lignes
        return
    }

    try {
        $disques = Get-PhysicalDisk -ErrorAction Stop
        foreach ($d in $disques) {
            $type = switch ($d.HealthStatus) {
                'Healthy' { 'OK' }
                'Warning' { 'ATTENTION' }
                default   { 'CRITIQUE' }
            }
            $lignes += Ecrire-Ligne -Type $type -Message "$($d.FriendlyName) - Type : $($d.MediaType) - Etat : $($d.HealthStatus)"
            $statuts += $type
        }
    } catch {
        try {
            $lignes += Ecrire-Ligne -Type 'INFO' -Message "Get-PhysicalDisk indisponible, lecture via wmic..."
            $wmicResult = wmic diskdrive get status,model 2>$null
            $lignes += ($wmicResult | Where-Object { $_.Trim() -ne '' })
        } catch {
            $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Impossible de lire l'etat S.M.A.R.T. : $($_.Exception.Message)"
        }
    }

    Ajouter-Resultat -Titre "2. Sante disque dur / SSD" -Statut (Get-PireStatut -Statuts $statuts) -Lignes $lignes
}

# --- Option 3 : RAM et processeur -----------------------------------------

function Analyse-RamCpu {
    Write-Host ""
    Write-Host "=== 3. RAM ET PROCESSEUR ===" -ForegroundColor White
    $lignes = @()
    $statuts = @()

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $totalGo = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $libreGo = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $utiliseGo = [math]::Round($totalGo - $libreGo, 1)
        $pourcentUtilise = [math]::Round(($utiliseGo / $totalGo) * 100, 0)
        $type = if ($pourcentUtilise -gt 90) { 'CRITIQUE' } elseif ($pourcentUtilise -gt 75) { 'ATTENTION' } else { 'OK' }
        $lignes += Ecrire-Ligne -Type $type -Message "RAM utilisee : $utiliseGo Go / $totalGo Go ($pourcentUtilise%)"
        $statuts += $type
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Lecture RAM impossible : $($_.Exception.Message)"
    }

    try {
        $cpuCharge = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 0)
        $type = if ($cpuCharge -gt 90) { 'CRITIQUE' } elseif ($cpuCharge -gt 70) { 'ATTENTION' } else { 'OK' }
        $lignes += Ecrire-Ligne -Type $type -Message "Charge CPU moyenne : $cpuCharge%"
        $statuts += $type
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Lecture charge CPU impossible : $($_.Exception.Message)"
    }

    try {
        $lignes += "--- Top 5 processus (RAM) ---"
        Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 5 | ForEach-Object {
            $l = "$($_.ProcessName) : $([math]::Round($_.WorkingSet / 1MB, 0)) Mo RAM"
            Write-Host "  $l" -ForegroundColor Gray
            $lignes += $l
        }
        $lignes += "--- Top 5 processus (CPU cumule) ---"
        Get-Process | Where-Object { $_.CPU } | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object {
            $l = "$($_.ProcessName) : $([math]::Round($_.CPU, 1)) sec CPU cumulees"
            Write-Host "  $l" -ForegroundColor Gray
            $lignes += $l
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Liste des processus impossible : $($_.Exception.Message)"
    }

    $lignes += Ecrire-Ligne -Type 'INFO' -Message "Temperature CPU/GPU non accessible nativement : utilisez un outil tiers (HWiNFO, OpenHardwareMonitor, Core Temp)."

    Ajouter-Resultat -Titre "3. RAM et processeur" -Statut (Get-PireStatut -Statuts $statuts) -Lignes $lignes
}

# --- Option 4 : Antivirus et securite -------------------------------------

function Analyse-Securite {
    Write-Host ""
    Write-Host "=== 4. ANTIVIRUS ET SECURITE ===" -ForegroundColor White
    $lignes = @()
    $statuts = @()

    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        $typeActif = if ($defender.AntivirusEnabled) { 'OK' } else { 'CRITIQUE' }
        $lignes += Ecrire-Ligne -Type $typeActif -Message "Windows Defender actif : $($defender.AntivirusEnabled)"
        $statuts += $typeActif

        $lignes += Ecrire-Ligne -Type 'INFO' -Message "Dernier scan rapide : $($defender.QuickScanEndTime)"
        $lignes += Ecrire-Ligne -Type 'INFO' -Message "Derniere mise a jour des definitions : $($defender.AntivirusSignatureLastUpdated)"

        if ($defender.AntivirusSignatureLastUpdated) {
            $ageDefinitions = (Get-Date) - $defender.AntivirusSignatureLastUpdated
            $typeDef = if ($ageDefinitions.Days -gt 7) { 'ATTENTION' } else { 'OK' }
            $lignes += Ecrire-Ligne -Type $typeDef -Message "Definitions vieilles de $($ageDefinitions.Days) jour(s)"
            $statuts += $typeDef
        }

        if (-not (Test-EstAdmin)) {
            $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Lancer un scan rapide necessite les droits administrateur."
        } elseif ($Global:ModeAutomatique) {
            $lignes += Ecrire-Ligne -Type 'INFO' -Message "Scan rapide non lance automatiquement (mode 'Tout analyser'). Lancez l'option 4 seule pour le declencher."
        } else {
            $reponse = Read-Host "  Lancer un scan rapide Windows Defender maintenant ? (O/N)"
            if ($reponse -match '^[oOyY]') {
                Write-Host "  Scan en cours, veuillez patienter..." -ForegroundColor Gray
                Start-MpScan -ScanType QuickScan
                $lignes += "Scan rapide lance le $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
                Write-Host "  Scan termine." -ForegroundColor Green
            }
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Windows Defender non accessible (peut etre remplace par un autre antivirus) : $($_.Exception.Message)"
    }

    try {
        Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object {
            $type = if ($_.Enabled) { 'OK' } else { 'CRITIQUE' }
            $lignes += Ecrire-Ligne -Type $type -Message "Pare-feu ($($_.Name)) : $(if ($_.Enabled) { 'Actif' } else { 'INACTIF' })"
            $statuts += $type
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Lecture pare-feu impossible : $($_.Exception.Message)"
    }

    Ajouter-Resultat -Titre "4. Antivirus et securite" -Statut (Get-PireStatut -Statuts $statuts) -Lignes $lignes
}

# --- Option 5 : Pilotes ----------------------------------------------------

function Analyse-Pilotes {
    Write-Host ""
    Write-Host "=== 5. PILOTES (DRIVERS) ===" -ForegroundColor White
    $lignes = @()
    $statuts = @()

    try {
        $erreurs = Get-PnpDevice -Status Error -ErrorAction SilentlyContinue
        if ($erreurs) {
            foreach ($e in $erreurs) {
                $lignes += Ecrire-Ligne -Type 'CRITIQUE' -Message "Pilote en erreur : $($e.FriendlyName)"
            }
            $statuts += 'CRITIQUE'
        } else {
            $lignes += Ecrire-Ligne -Type 'OK' -Message "Aucun pilote en erreur detecte"
            $statuts += 'OK'
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Liste des pilotes impossible : $($_.Exception.Message)"
    }

    try {
        $gpu = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -eq 'DISPLAY' } | Select-Object -First 1
        if ($gpu -and $gpu.DriverDate) {
            $dateDriver = [Management.ManagementDateTimeConverter]::ToDateTime($gpu.DriverDate)
            $ageAns = ((Get-Date) - $dateDriver).Days / 365
            $type = if ($ageAns -gt 1) { 'ATTENTION' } else { 'OK' }
            $lignes += Ecrire-Ligne -Type $type -Message "Pilote graphique ($($gpu.DeviceName)) date du $($dateDriver.ToString('dd/MM/yyyy'))"
            $statuts += $type
        } else {
            $lignes += Ecrire-Ligne -Type 'INFO' -Message "Impossible de determiner la date du pilote graphique"
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Lecture pilote graphique impossible : $($_.Exception.Message)"
    }

    Ajouter-Resultat -Titre "5. Pilotes" -Statut (Get-PireStatut -Statuts $statuts) -Lignes $lignes
}

# --- Option 6 : Peripheriques externes ------------------------------------

function Analyse-PeripheriquesExternes {
    Write-Host ""
    Write-Host "=== 6. PERIPHERIQUES EXTERNES ===" -ForegroundColor White
    $lignes = @()

    try {
        $lignes += "--- Peripheriques USB actuellement connectes ---"
        Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB*' } |
            Select-Object -Unique FriendlyName | ForEach-Object {
                Write-Host "  $($_.FriendlyName)" -ForegroundColor Gray
                $lignes += $_.FriendlyName
            }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Liste des peripheriques connectes impossible : $($_.Exception.Message)"
    }

    try {
        $lignes += "--- Historique des cles USB / disques externes deja connectes ---"
        Get-PnpDevice | Where-Object { $_.InstanceId -like 'USBSTOR*' } |
            Select-Object -Unique FriendlyName | ForEach-Object {
                Write-Host "  $($_.FriendlyName)" -ForegroundColor Gray
                $lignes += $_.FriendlyName
            }
        if (-not (Test-EstAdmin)) {
            $lignes += Ecrire-Ligne -Type 'INFO' -Message "L'historique peut etre incomplet sans droits administrateur."
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Historique des peripheriques impossible : $($_.Exception.Message)"
    }

    Ajouter-Resultat -Titre "6. Peripheriques externes" -Statut 'OK' -Lignes $lignes
}

# --- Option 7 : Demarrage et performances ---------------------------------

function Analyse-Demarrage {
    Write-Host ""
    Write-Host "=== 7. DEMARRAGE ET PERFORMANCES ===" -ForegroundColor White
    $lignes = @()
    $statuts = @()

    try {
        $programmes = Get-CimInstance Win32_StartupCommand
        $nonEssentiels = @('Spotify', 'Steam', 'Discord', 'Skype', 'Teams', 'Adobe', 'iTunes', 'EpicGamesLauncher')
        $lignes += "--- Programmes lances au demarrage ---"
        foreach ($p in $programmes) {
            $suggestion = if ($nonEssentiels | Where-Object { $p.Name -like "*$_*" }) { " -> peut etre desactive sans risque" } else { "" }
            $l = "$($p.Name) ($($p.Location))$suggestion"
            Write-Host "  $l" -ForegroundColor Gray
            $lignes += $l
        }
        $type = if ($programmes.Count -gt 15) { 'ATTENTION' } else { 'OK' }
        $lignes += Ecrire-Ligne -Type $type -Message "$($programmes.Count) programme(s) au demarrage"
        $statuts += $type
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Liste des programmes au demarrage impossible : $($_.Exception.Message)"
    }

    try {
        $evenement = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
        $xml = [xml]$evenement.ToXml()
        $dureeMs = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' } | Select-Object -ExpandProperty '#text'
        if ($dureeMs) {
            $dureeSec = [math]::Round($dureeMs / 1000, 1)
            $type = if ($dureeSec -gt 60) { 'ATTENTION' } else { 'OK' }
            $lignes += Ecrire-Ligne -Type $type -Message "Dernier temps de demarrage estime : $dureeSec secondes"
            $statuts += $type
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'INFO' -Message "Temps de demarrage non disponible (journal d'evenements inaccessible)."
    }

    Ajouter-Resultat -Titre "7. Demarrage et performances" -Statut (Get-PireStatut -Statuts $statuts) -Lignes $lignes
}

# --- Option 8 : Reseau ------------------------------------------------------

function Analyse-Reseau {
    Write-Host ""
    Write-Host "=== 8. RESEAU ===" -ForegroundColor White
    $lignes = @()
    $statuts = @()

    try {
        $ping = Test-Connection -ComputerName 8.8.8.8 -Count 4 -ErrorAction Stop
        $latences = $ping | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains 'ResponseTime') { $_.ResponseTime } else { $_.Latency }
        }
        $latenceMoy = [math]::Round(($latences | Measure-Object -Average).Average, 0)
        $type = if ($latenceMoy -gt 400) { 'CRITIQUE' } elseif ($latenceMoy -gt 150) { 'ATTENTION' } else { 'OK' }
        $lignes += Ecrire-Ligne -Type $type -Message "Connexion internet OK - latence moyenne : $latenceMoy ms"
        $statuts += $type
    } catch {
        $lignes += Ecrire-Ligne -Type 'CRITIQUE' -Message "Pas de connexion internet detectee"
        $statuts += 'CRITIQUE'
    }

    try {
        Write-Host "  Test de debit approximatif (telechargement d'un fichier de test externe)..." -ForegroundColor Gray
        $urlTest = "https://speed.hetzner.de/100MB.bin"
        $fichierTemp = Join-Path $env:TEMP "test_debit.tmp"
        $chrono = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-WebRequest -Uri $urlTest -OutFile $fichierTemp -TimeoutSec 15 -ErrorAction Stop
        $chrono.Stop()
        $tailleMo = (Get-Item $fichierTemp).Length / 1MB
        $debitMbps = [math]::Round(($tailleMo * 8) / $chrono.Elapsed.TotalSeconds, 1)
        Remove-Item $fichierTemp -ErrorAction SilentlyContinue
        $type = if ($debitMbps -lt 5) { 'ATTENTION' } else { 'OK' }
        $lignes += Ecrire-Ligne -Type $type -Message "Debit descendant approximatif : $debitMbps Mbps"
        $statuts += $type
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Test de debit impossible (connexion trop lente ou serveur de test injoignable)"
    }

    try {
        $ipLocale = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notlike '169.254*' } |
            Select-Object -First 1).IPAddress
        $lignes += Ecrire-Ligne -Type 'INFO' -Message "Adresse IP locale : $ipLocale"
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Adresse IP locale non determinee"
    }

    try {
        $ipPublique = Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5 -ErrorAction Stop
        $lignes += Ecrire-Ligne -Type 'INFO' -Message "Adresse IP publique : $ipPublique"
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Adresse IP publique non determinee (pas de connexion internet ou service injoignable)"
    }

    try {
        $lignes += "--- Reseaux Wi-Fi enregistres ---"
        (netsh wlan show profiles) -match "\s:\s" | ForEach-Object {
            $nom = ($_ -split ":")[1].Trim()
            Write-Host "  $nom" -ForegroundColor Gray
            $lignes += $nom
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'INFO' -Message "Liste des reseaux Wi-Fi non disponible (pas d'adaptateur Wi-Fi ?)"
    }

    Ajouter-Resultat -Titre "8. Reseau" -Statut (Get-PireStatut -Statuts $statuts) -Lignes $lignes
}

# --- Option 9 : Mises a jour Windows ---------------------------------------

function Analyse-MisesAJour {
    Write-Host ""
    Write-Host "=== 9. MISES A JOUR WINDOWS ===" -ForegroundColor White
    $lignes = @()
    $statuts = @()

    try {
        $derniere = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($derniere) {
            $lignes += Ecrire-Ligne -Type 'INFO' -Message "Derniere mise a jour installee : $($derniere.HotFixID) le $($derniere.InstalledOn)"
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Historique des mises a jour impossible : $($_.Exception.Message)"
    }

    try {
        Write-Host "  Recherche de mises a jour en attente (peut prendre 30 a 60 secondes)..." -ForegroundColor Gray
        $session = New-Object -ComObject Microsoft.Update.Session
        $recherche = $session.CreateUpdateSearcher()
        $resultat = $recherche.Search("IsInstalled=0 and Type='Software'")
        $nbEnAttente = $resultat.Updates.Count
        $type = if ($nbEnAttente -gt 0) { 'ATTENTION' } else { 'OK' }
        $lignes += Ecrire-Ligne -Type $type -Message "$nbEnAttente mise(s) a jour en attente"
        $statuts += $type
        for ($i = 0; $i -lt [math]::Min($nbEnAttente, 10); $i++) {
            $l = " - $($resultat.Updates.Item($i).Title)"
            Write-Host "  $l" -ForegroundColor Gray
            $lignes += $l
        }
    } catch {
        $lignes += Ecrire-Ligne -Type 'ATTENTION' -Message "Recherche des mises a jour en attente impossible : $($_.Exception.Message)"
    }

    Ajouter-Resultat -Titre "9. Mises a jour Windows" -Statut (Get-PireStatut -Statuts $statuts) -Lignes $lignes
}

# --- Resume et export --------------------------------------------------

function Afficher-Resume {
    if ($Global:RapportResultats.Count -eq 0) {
        Write-Host "`nAucune analyse n'a encore ete lancee." -ForegroundColor Yellow
        return
    }
    Write-Host "`n=== RESUME (points a surveiller) ===" -ForegroundColor White
    $aSurveiller = $Global:RapportResultats | Where-Object { $_.Statut -ne 'OK' }
    if ($aSurveiller.Count -eq 0) {
        Write-Host "  Aucun point critique detecte. Le PC est en bon etat general." -ForegroundColor Green
        return
    }
    $aSurveiller | Select-Object -First 6 | ForEach-Object {
        $couleur = if ($_.Statut -eq 'CRITIQUE') { 'Red' } else { 'Yellow' }
        Write-Host "  [$($_.Statut)] $($_.Titre)" -ForegroundColor $couleur
    }
}

function Exporter-Rapport {
    if ($Global:RapportResultats.Count -eq 0) {
        Write-Host "`nAucune analyse a exporter. Lancez d'abord une ou plusieurs analyses." -ForegroundColor Yellow
        return
    }

    $nomFichier = "rapport_diagnostic_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $chemin = Join-Path -Path (Get-Location) -ChildPath $nomFichier

    $contenu = @()
    $contenu += "RAPPORT DE DIAGNOSTIC PC"
    $contenu += "Genere le $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
    $contenu += "Ordinateur : $env:COMPUTERNAME"
    $contenu += "=" * 50
    $contenu += ""

    foreach ($resultat in $Global:RapportResultats) {
        $contenu += "--- $($resultat.Titre) [$($resultat.Statut)] ---"
        $contenu += $resultat.Lignes
        $contenu += ""
    }

    $contenu += "=" * 50
    $contenu += "RESUME"
    $aSurveiller = $Global:RapportResultats | Where-Object { $_.Statut -ne 'OK' }
    if ($aSurveiller.Count -eq 0) {
        $contenu += "Aucun point critique detecte."
    } else {
        $aSurveiller | Select-Object -First 6 | ForEach-Object { $contenu += "[$($_.Statut)] $($_.Titre)" }
    }

    try {
        $contenu | Out-File -FilePath $chemin -Encoding UTF8
        Write-Host "`nRapport exporte : $chemin" -ForegroundColor Green
    } catch {
        Write-Host "`nImpossible d'exporter le rapport : $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Menu principal ----------------------------------------------------

function Afficher-Menu {
    Write-Host ""
    Write-Host "=======================================" -ForegroundColor Cyan
    Write-Host "     DIAGNOSTIC ET MAINTENANCE PC" -ForegroundColor Cyan
    Write-Host "=======================================" -ForegroundColor Cyan
    if (Test-EstAdmin) {
        Write-Host "  Mode : Administrateur" -ForegroundColor Green
    } else {
        Write-Host "  Mode : Utilisateur standard (certaines analyses seront limitees)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  0 - Tout analyser"
    Write-Host "  1 - Espace disque"
    Write-Host "  2 - Sante disque dur / SSD (admin requis)"
    Write-Host "  3 - RAM et processeur"
    Write-Host "  4 - Antivirus et securite"
    Write-Host "  5 - Pilotes"
    Write-Host "  6 - Peripheriques externes"
    Write-Host "  7 - Demarrage et performances"
    Write-Host "  8 - Reseau"
    Write-Host "  9 - Mises a jour Windows"
    Write-Host "  R - Resume de la derniere analyse"
    Write-Host "  E - Exporter le rapport texte"
    Write-Host "  Q - Quitter"
    Write-Host ""
}

do {
    Afficher-Menu
    $choix = (Read-Host "Votre choix").ToUpper()

    switch ($choix) {
        '0' {
            $Global:RapportResultats = @()
            $Global:ModeAutomatique = $true
            Analyse-EspaceDisque
            Analyse-SanteDisque
            Analyse-RamCpu
            Analyse-Securite
            Analyse-Pilotes
            Analyse-PeripheriquesExternes
            Analyse-Demarrage
            Analyse-Reseau
            Analyse-MisesAJour
            $Global:ModeAutomatique = $false
            Afficher-Resume
        }
        '1' { Analyse-EspaceDisque }
        '2' { Analyse-SanteDisque }
        '3' { Analyse-RamCpu }
        '4' { Analyse-Securite }
        '5' { Analyse-Pilotes }
        '6' { Analyse-PeripheriquesExternes }
        '7' { Analyse-Demarrage }
        '8' { Analyse-Reseau }
        '9' { Analyse-MisesAJour }
        'R' { Afficher-Resume }
        'E' { Exporter-Rapport }
        'Q' { Write-Host "`nFermeture du diagnostic." -ForegroundColor Cyan }
        default { Write-Host "`nChoix invalide." -ForegroundColor Red }
    }

    if ($choix -ne 'Q') {
        Write-Host "`nAppuyez sur une touche pour revenir au menu..." -ForegroundColor Gray
        [void][System.Console]::ReadKey($true)
    }
} while ($choix -ne 'Q')
