
  param (
    # get, don't execute
    [Parameter(Mandatory=$false)]
    [Alias("g")]
    [switch] $get = $false,

    # run local, don't download, assume everything is ready
    [Parameter(Mandatory=$false)]
    [Alias("l")]
    [Alias("loc")]
    [switch] $local = $false,

    # keep the build directories, don't clear them
    [Parameter(Mandatory=$false)]
    [Alias("c")]
    [Alias("cont")]
    [switch] $continue = $false
  )

  # ################################################################
  # BOOTSTRAP
  # ################################################################

  # create and boot the buildsystem
  $ubuild = &"$PSScriptRoot\build-bootstrap.ps1"
  if (-not $?) { return }
  $ubuild.Boot($PSScriptRoot,
    @{ Local = $local; },
    @{ Continue = $continue })
  if ($ubuild.OnError()) { return }

  Write-Host "Umbraco Cms Build"
  Write-Host "Umbraco.Build v$($ubuild.BuildVersion)"

  # ################################################################
  # TASKS
  # ################################################################

  $ubuild.DefineMethod("SetMoreUmbracoVersion",
  {
    param ( $semver )

    $release = "" + $semver.Major + "." + $semver.Minor + "." + $semver.Patch

    Write-Host "Update UmbracoVersion.cs"
    $this.ReplaceFileText("$($this.SolutionRoot)\src\Umbraco.Core\Configuration\UmbracoVersion.cs", `
      "(\d+)\.(\d+)\.(\d+)(.(\d+))?", `
      "$release")
    $this.ReplaceFileText("$($this.SolutionRoot)\src\Umbraco.Core\Configuration\UmbracoVersion.cs", `
      "CurrentComment => `"(.+)`"", `
      "CurrentComment => `"$($semver.PreRelease)`"")

    Write-Host "Update IIS Express port in csproj"
    $updater = New-Object "Umbraco.Build.ExpressPortUpdater"
    $csproj = "$($this.SolutionRoot)\src\Umbraco.Web.UI\Umbraco.Web.UI.csproj"
    $updater.Update($csproj, $release)
  })

  $ubuild.DefineMethod("SandboxNode",
  {
    $global:node_path = $env:path
    $nodePath = $this.BuildEnv.NodePath
    $gitExe = (Get-Command git).Source
    if (-not $gitExe) { $gitExe = (Get-Command git).Path }
    $gitPath = [System.IO.Path]::GetDirectoryName($gitExe)
    $env:path = "$nodePath;$gitPath"

    $global:node_nodepath = $this.ClearEnvVar("NODEPATH")
    $global:node_npmcache = $this.ClearEnvVar("NPM_CONFIG_CACHE")
    $global:node_npmprefix = $this.ClearEnvVar("NPM_CONFIG_PREFIX")
  })

  $ubuild.DefineMethod("RestoreNode",
  {
    $env:path = $node_path

    $this.SetEnvVar("NODEPATH", $node_nodepath)
    $this.SetEnvVar("NPM_CONFIG_CACHE", $node_npmcache)
    $this.SetEnvVar("NPM_CONFIG_PREFIX", $node_npmprefix)
  })

  $ubuild.DefineMethod("CompileBelle",
  {
    $src = "$($this.SolutionRoot)\src"
    $log = "$($this.BuildTemp)\belle.log"

    Write-Host "Compile Belle"
    Write-Host "Logging to $log"

    # get a temp clean node env (will restore)
    $this.SandboxNode()

    # stupid PS is going to gather all "warnings" in $error
    # so we have to take care of it else they'll bubble and kill the build
    if ($error.Count -gt 0) { return }

    Push-Location "$($this.SolutionRoot)\src\Umbraco.Web.UI.Client"
    Write-Output "" > $log

    Write-Output "### node version is:" > $log
    &node -v >> $log 2>&1
    if (-not $?) { throw "Failed to report node version." }

    Write-Output "### npm version is:" >> $log 2>&1
    &npm -v >> $log 2>&1
    if (-not $?) { throw "Failed to report npm version." }

    Write-Output "### clean npm cache" >> $log 2>&1
    &npm cache clean --force >> $log 2>&1
    $error.Clear() # that one can fail 'cos security bug - ignore

    Write-Output "### npm install" >> $log 2>&1
    &npm install >> $log 2>&1
    Write-Output ">> $? $($error.Count)" >> $log 2>&1

    Write-Output "### install bower" >> $log 2>&1
    &npm install -g bower >> $log 2>&1
    $error.Clear() # that one fails 'cos bower is deprecated - ignore

    Write-Output "### install gulp" >> $log 2>&1
    &npm install -g gulp >> $log 2>&1
    $error.Clear() # that one fails 'cos deprecated stuff - ignore

    Write-Output "### install gulp-cli" >> $log 2>&1
    &npm install -g gulp-cli --quiet >> $log 2>&1
    if (-not $?) { throw "Failed to install gulp-cli" } # that one is expected to work

    Write-Output "### gulp build for version $($this.Version.Release)" >> $log 2>&1
    &gulp build --buildversion=$this.Version.Release >> $log 2>&1
    if (-not $?) { throw "Failed to build" } # that one is expected to work

    Pop-Location

    # fixme - should we filter the log to find errors?
    #get-content .\build.tmp\belle.log | %{ if ($_ -match "build") { write $_}}

    # restore
    $this.RestoreNode()

    # setting node_modules folder to hidden
    # used to prevent VS13 from crashing on it while loading the websites project
    # also makes sure aspnet compiler does not try to handle rogue files and chokes
    # in VSO with Microsoft.VisualC.CppCodeProvider -related errors
    # use get-item -force 'cos it might be hidden already
    Write-Host "Set hidden attribute on node_modules"
    $dir = Get-Item -force "$src\Umbraco.Web.UI.Client\node_modules"
    $dir.Attributes = $dir.Attributes -bor ([System.IO.FileAttributes]::Hidden)
  })

  $ubuild.DefineMethod("CompileUmbraco",
  {
    $buildConfiguration = "Release"

    $src = "$($this.SolutionRoot)\src"
    $log = "$($this.BuildTemp)\msbuild.umbraco.log"

    if ($this.BuildEnv.VisualStudio -eq $null)
    {
      throw "Build environment does not provide VisualStudio."
    }

    Write-Host "Compile Umbraco"
    Write-Host "Logging to $log"

    # beware of the weird double \\ at the end of paths
    # see http://edgylogic.com/blog/powershell-and-external-commands-done-right/
    &$this.BuildEnv.VisualStudio.MsBuild "$src\Umbraco.Web.UI\Umbraco.Web.UI.csproj" `
      /p:WarningLevel=0 `
      /p:Configuration=$buildConfiguration `
      /p:Platform=AnyCPU `
      /p:UseWPP_CopyWebApplication=True `
      /p:PipelineDependsOnBuild=False `
      /p:OutDir="$($this.BuildTemp)\bin\\" `
      /p:WebProjectOutputDir="$($this.BuildTemp)\WebApp\\" `
      /p:Verbosity=minimal `
      /t:Clean`;Rebuild `
      /tv:"$($this.BuildEnv.VisualStudio.ToolsVersion)" `
      /p:UmbracoBuild=True `
      > $log

    if (-not $?) { throw "Failed to compile Umbraco.Web.UI." }

    # /p:UmbracoBuild tells the csproj that we are building from PS, not VS
  })

  $ubuild.DefineMethod("PrepareTests",
  {
    Write-Host "Prepare Tests"

    # fixme - idea is to avoid rebuilding everything for tests
    # but because of our weird assembly versioning (with .* stuff)
    # everything gets rebuilt all the time...
    #Copy-Files "$tmp\bin" "." "$tmp\tests"

    # data
    Write-Host "Copy data files"
    if (-not (Test-Path -Path "$($this.BuildTemp)\tests\Packaging" ))
    {
      Write-Host "Create packaging directory"
      mkdir "$($this.BuildTemp)\tests\Packaging" > $null
    }
    $this.CopyFiles("$($this.SolutionRoot)\src\Umbraco.Tests\Packaging\Packages", "*", "$($this.BuildTemp)\tests\Packaging\Packages")

    # required for package install tests
    if (-not (Test-Path -Path "$($this.BuildTemp)\tests\bin" ))
    {
      Write-Host "Create bin directory"
      mkdir "$($this.BuildTemp)\tests\bin" > $null
    }
  })

  $ubuild.DefineMethod("CompileTests",
  {
    $buildConfiguration = "Release"
    $log = "$($this.BuildTemp)\msbuild.tests.log"

    if ($this.BuildEnv.VisualStudio -eq $null)
    {
      throw "Build environment does not provide VisualStudio."
    }

    Write-Host "Compile Tests"
    Write-Host "Logging to $log"

    # beware of the weird double \\ at the end of paths
    # see http://edgylogic.com/blog/powershell-and-external-commands-done-right/
    &$this.BuildEnv.VisualStudio.MsBuild "$($this.SolutionRoot)\src\Umbraco.Tests\Umbraco.Tests.csproj" `
      /p:WarningLevel=0 `
      /p:Configuration=$buildConfiguration `
      /p:Platform=AnyCPU `
      /p:UseWPP_CopyWebApplication=True `
      /p:PipelineDependsOnBuild=False `
      /p:OutDir="$($this.BuildTemp)\tests\\" `
      /p:Verbosity=minimal `
      /t:Build `
      /tv:"$($this.BuildEnv.VisualStudio.ToolsVersion)" `
      /p:UmbracoBuild=True `
      > $log

    if (-not $?) { throw "Failed to compile tests." }

    # /p:UmbracoBuild tells the csproj that we are building from PS
  })

  $ubuild.DefineMethod("PreparePackages",
  {
    Write-Host "Prepare Packages"

    $src = "$($this.SolutionRoot)\src"
    $tmp = "$($this.BuildTemp)"
    $out = "$($this.BuildOutput)"

    $buildConfiguration = "Release"

    # restore web.config
    $this.TempRestoreFile("$src\Umbraco.Web.UI\web.config")

    # cleanup build
    Write-Host "Clean build"
    $this.RemoveFile("$tmp\bin\*.dll.config")
    $this.RemoveFile("$tmp\WebApp\bin\*.dll.config")

    # cleanup presentation
    Write-Host "Cleanup presentation"
    $this.RemoveDirectory("$tmp\WebApp\umbraco.presentation")

    # create directories
    Write-Host "Create directories"
    mkdir "$tmp\Configs" > $null
    mkdir "$tmp\Configs\Lang" > $null
    mkdir "$tmp\WebApp\App_Data" > $null
    #mkdir "$tmp\WebApp\Media" > $null
    #mkdir "$tmp\WebApp\Views" > $null

    # copy various files
    Write-Host "Copy xml documentation"
    Copy-Item -force "$tmp\bin\*.xml" "$tmp\WebApp\bin"

    Write-Host "Copy transformed configs and langs"
    # note: exclude imageprocessor/*.config as imageprocessor pkg installs them
    $this.CopyFiles("$tmp\WebApp\config", "*.config", "$tmp\Configs", `
      { -not $_.RelativeName.StartsWith("imageprocessor") })
    $this.CopyFiles("$tmp\WebApp\config", "*.js", "$tmp\Configs")
    $this.CopyFiles("$tmp\WebApp\config\lang", "*.xml", "$tmp\Configs\Lang")
    $this.CopyFile("$tmp\WebApp\web.config", "$tmp\Configs\web.config.transform")

    Write-Host "Copy transformed web.config"
    $this.CopyFile("$src\Umbraco.Web.UI\web.$buildConfiguration.Config.transformed", "$tmp\WebApp\web.config")

    # offset the modified timestamps on all umbraco dlls, as WebResources
    # break if date is in the future, which, due to timezone offsets can happen.
    Write-Host "Offset dlls timestamps"
    Get-ChildItem -r "$tmp\*.dll" | ForEach-Object {
      $_.CreationTime = $_.CreationTime.AddHours(-11)
      $_.LastWriteTime = $_.LastWriteTime.AddHours(-11)
    }

    # copy libs
    Write-Host "Copy SqlCE libraries"
    $nugetPackages = $env:NUGET_PACKAGES
    if (-not $nugetPackages)
    {
      $nugetPackages = [System.Environment]::ExpandEnvironmentVariables("%userprofile%\.nuget\packages")
    }
    $this.CopyFiles("$nugetPackages\umbraco.sqlserverce\4.0.0.1\runtimes\win-x86\native", "*.*", "$tmp\bin\x86")
    $this.CopyFiles("$nugetPackages\umbraco.sqlserverce\4.0.0.1\runtimes\win-x64\native", "*.*", "$tmp\bin\amd64")
    $this.CopyFiles("$nugetPackages\umbraco.sqlserverce\4.0.0.1\runtimes\win-x86\native", "*.*", "$tmp\WebApp\bin\x86")
    $this.CopyFiles("$nugetPackages\umbraco.sqlserverce\4.0.0.1\runtimes\win-x64\native", "*.*", "$tmp\WebApp\bin\amd64")

    # copy Belle
    Write-Host "Copy Belle"
    $this.CopyFiles("$src\Umbraco.Web.UI\umbraco\assets", "*", "$tmp\WebApp\umbraco\assets")
    $this.CopyFiles("$src\Umbraco.Web.UI\umbraco\js", "*", "$tmp\WebApp\umbraco\js")
    $this.CopyFiles("$src\Umbraco.Web.UI\umbraco\lib", "*", "$tmp\WebApp\umbraco\lib")
    $this.CopyFiles("$src\Umbraco.Web.UI\umbraco\views", "*", "$tmp\WebApp\umbraco\views")
  })

  $ubuild.DefineMethod("PackageZip",
  {
    Write-Host "Create Zip packages"

    $src = "$($this.SolutionRoot)\src"
    $tmp = $this.BuildTemp
    $out = $this.BuildOutput

    Write-Host "Zip all binaries"
    &$this.BuildEnv.Zip a -r "$out\UmbracoCms.AllBinaries.$($this.Version.Semver).zip" `
      "$tmp\bin\*" `
      "-x!dotless.Core.*" `
      > $null
    if (-not $?) { throw "Failed to zip UmbracoCms.AllBinaries." }

    Write-Host "Zip cms"
    &$this.BuildEnv.Zip a -r "$out\UmbracoCms.$($this.Version.Semver).zip" `
      "$tmp\WebApp\*" `
      "-x!dotless.Core.*" "-x!Content_Types.xml" "-x!*.pdb" `
      > $null
    if (-not $?) { throw "Failed to zip UmbracoCms." }
  })

  $ubuild.DefineMethod("PrepareBuild",
  {
    Write-Host "Clear folders and files"
    $this.RemoveDirectory("$($this.SolutionRoot)\src\Umbraco.Web.UI.Client\bower_components")

    $this.TempStoreFile("$($this.SolutionRoot)\src\Umbraco.Web.UI\web.config")
    Write-Host "Create clean web.config"
    $this.CopyFile("$($this.SolutionRoot)\src\Umbraco.Web.UI\web.Template.config", "$($this.SolutionRoot)\src\Umbraco.Web.UI\web.config")

    Write-host "Set environment"
    $env:UMBRACO_VERSION=$this.Version.Semver.ToString()
    $env:UMBRACO_RELEASE=$this.Version.Release
    $env:UMBRACO_COMMENT=$this.Version.Comment
    $env:UMBRACO_BUILD=$this.Version.Build

    if ($args -and $args[0] -eq "vso")
    {
      Write-host "Set VSO environment"
      # set environment variable for VSO
      # https://github.com/Microsoft/vsts-tasks/issues/375
      # https://github.com/Microsoft/vsts-tasks/blob/master/docs/authoring/commands.md
      Write-Host ("##vso[task.setvariable variable=UMBRACO_VERSION;]$($this.Version.Semver.ToString())")
      Write-Host ("##vso[task.setvariable variable=UMBRACO_RELEASE;]$($this.Version.Release)")
      Write-Host ("##vso[task.setvariable variable=UMBRACO_COMMENT;]$($this.Version.Comment)")
      Write-Host ("##vso[task.setvariable variable=UMBRACO_BUILD;]$($this.Version.Build)")

      Write-Host ("##vso[task.setvariable variable=UMBRACO_TMP;]$($this.SolutionRoot)\build.tmp")
    }
  })

  $ubuild.DefineMethod("PrepareNuGet",
  {
    Write-Host "Prepare NuGet"

    # add Web.config transform files to the NuGet package
    Write-Host "Add web.config transforms to NuGet package"
    mv "$($this.BuildTemp)\WebApp\Views\Web.config" "$($this.BuildTemp)\WebApp\Views\Web.config.transform"

  })

  $ubuild.DefineMethod("RestoreNuGet",
  {
    Write-Host "Restore NuGet"
    Write-Host "Logging to $($this.BuildTemp)\nuget.restore.log"
    &$this.BuildEnv.NuGet restore "$($this.SolutionRoot)\src\Umbraco.sln" > "$($this.BuildTemp)\nuget.restore.log"
    if (-not $?) { throw "Failed to restore NuGet packages." }
  })

  $ubuild.DefineMethod("PackageNuGet",
  {
    $nuspecs = "$($this.SolutionRoot)\build\NuSpecs"

    Write-Host "Create NuGet packages"

    &$this.BuildEnv.NuGet Pack "$nuspecs\UmbracoCms.Core.nuspec" `
        -Properties BuildTmp="$($this.BuildTemp)" `
        -Version "$($this.Version.Semver.ToString())" `
        -Symbols -Verbosity detailed -outputDirectory "$($this.BuildOutput)" > "$($this.BuildTemp)\nupack.cmscore.log"
    if (-not $?) { throw "Failed to pack NuGet UmbracoCms.Core." }

    &$this.BuildEnv.NuGet Pack "$nuspecs\UmbracoCms.Web.nuspec" `
        -Properties BuildTmp="$($this.BuildTemp)" `
        -Version "$($this.Version.Semver.ToString())" `
        -Symbols -Verbosity detailed -outputDirectory "$($this.BuildOutput)" > "$($this.BuildTemp)\nupack.cmsweb.log"
    if (-not $?) { throw "Failed to pack NuGet UmbracoCms.Web." }

    &$this.BuildEnv.NuGet Pack "$nuspecs\UmbracoCms.nuspec" `
        -Properties BuildTmp="$($this.BuildTemp)" `
        -Version "$($this.Version.Semver.ToString())" `
        -Verbosity detailed -outputDirectory "$($this.BuildOutput)" > "$($this.BuildTemp)\nupack.cms.log"
    if (-not $?) { throw "Failed to pack NuGet UmbracoCms." }

    # run hook
    if ($this.HasMethod("PostPackageNuGet"))
    {
      Write-Host "Run PostPackageNuGet hook"
      $this.PostPackageNuGet();
      if (-not $?) { throw "Failed to run hook." }
    }
  })

  $ubuild.DefineMethod("VerifyNuGet",
  {
    $this.VerifyNuGetConsistency(
      ("UmbracoCms", "UmbracoCms.Core", "UmbracoCms.Web"),
      ("Umbraco.Core", "Umbraco.Web", "Umbraco.Web.UI", "Umbraco.Examine"))
    if ($this.OnError()) { return }
  })

  $ubuild.DefineMethod("PrepareAzureGallery",
  {
    Write-Host "Prepare Azure Gallery"
    $this.CopyFile("$($this.SolutionRoot)\build\Azure\azuregalleryrelease.ps1", $this.BuildOutput)
  })

  $ubuild.DefineMethod("Build",
  {
    $error.Clear()

    $this.PrepareBuild()
    if ($this.OnError()) { return }
    $this.RestoreNuGet()
    if ($this.OnError()) { return }
    $this.CompileBelle()
    if ($this.OnError()) { return }
    $this.CompileUmbraco()
    if ($this.OnError()) { return }
    $this.PrepareTests()
    if ($this.OnError()) { return }
    $this.CompileTests()
    if ($this.OnError()) { return }
    # not running tests
    $this.PreparePackages()
    if ($this.OnError()) { return }
    $this.PackageZip()
    if ($this.OnError()) { return }
    $this.VerifyNuGet()
    if ($this.OnError()) { return }
    $this.PrepareNuGet()
    if ($this.OnError()) { return }
    $this.PackageNuGet()
    if ($this.OnError()) { return }
    $this.PrepareAzureGallery()
    if ($this.OnError()) { return }
  })

  # ################################################################
  # RUN
  # ################################################################

  # configure
  $ubuild.ReleaseBranches = @( "master" )

  # run
  if (-not $get)
  {
    $ubuild.Build()
    if ($ubuild.OnError()) { return }
  }
  Write-Host "Done"
  if ($get) { return $ubuild }
