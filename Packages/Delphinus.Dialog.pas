{
#########################################################
# Copyright by Alexander Benikowski                     #
# This unit is part of the Delphinus project hosted on  #
# https://github.com/Memnarch/Delphinus                 #
#########################################################
}
unit Delphinus.Dialog;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics,
  Controls, Forms, Dialogs,
  DN.PackageOverview, ActnList, ImgList, ToolWin,
  ComCtrls,
  DN.PackageProvider.Intf,
  DN.Package.Intf,
  ContNrs,
  Generics.Collections,
  DN.PackageDetailView,
  Delphinus.Form,
  Delphinus.Settings,
  DN.Setup.Intf,
  Delphinus.CategoryFilterView,
  Delphinus.ProgressDialog;

type
  TDelphinusDialog = class(TDelphinusForm)
    ToolBar1: TToolBar;
    imgMenu: TImageList;
    DialogActions: TActionList;
    ToolButton1: TToolButton;
    actRefresh: TAction;
    ToolButton2: TToolButton;
    btnInstallFolder: TToolButton;
    dlgSelectInstallFile: TOpenDialog;
    btnUninstall: TToolButton;
    dlgSelectUninstallFile: TOpenDialog;
    actOptions: TAction;
    procedure actRefreshExecute(Sender: TObject);
    procedure btnInstallFolderClick(Sender: TObject);
    procedure btnUninstallClick(Sender: TObject);
    procedure actOptionsExecute(Sender: TObject);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
  private
    { Private declarations }
    FOverView: TPackageOverView;
    FPackageProvider: IDNPackageProvider;
    FInstalledPackageProvider: IDNPackageProvider;
    FPackages: TList<IDNPackage>;
    FInstalledPackages: TList<IDNPackage>;
    FUpdatePackages: TList<IDNPackage>;
    FDetailView: TPackageDetailView;
    FSettings: TDelphinusSettings;
    FCategoryFilteView: TCategoryFilterView;
    FCategory: TPackageCategory;
    FProgressDialog: TProgressDialog;
    procedure InstallPackage(const APackage: IDNPackage);
    procedure UnInstallPackage(const APackage: IDNPackage);
    procedure UpdatePackage(const APackage: IDNPackage);
    function GetComponentDirectory: string;
    function GetBPLDirectory: string;
    function GetDCPDirectory: string;
    procedure RefreshInstalledPackages;
    function IsPackageInstalled(const APackage: IDNPackage): Boolean;
    function GetInstalledPackage(const APackage: IDNPackage): IDNPackage;
    function GetOverviewPackage(const APackage: IDNPackage): IDNPackage;
    function GetInstalledVersion(const APackage: IDNPackage): string;
    function GetUpdateVersion(const APackage: IDNPackage): string;
    function GetActiveOverView: TPackageOverView;
    procedure ShowDetail(const APackage: IDNPackage);
    procedure LoadSettings(out ASettings: TDelphinusSettings);
    procedure SaveSettings(const ASettings: TDelphinusSettings);
    procedure RecreatePackageProvider();
    function CreateSetup: IDNSetup;
    procedure HandleCategoryChanged(Sender: TObject; ANewCategory: TPackageCategory);
    function GetActivePackageSource: TList<IDNPackage>;
    procedure RefreshOverview();
  public
    { Public declarations }
    constructor Create(AOwner: TComponent); override;
    destructor Destroy(); override;
  end;

var
  DelphinusDialog: TDelphinusDialog;

implementation

uses
  ToolsApi,
  IOUtils,
  RTTI,
  Types,
  Registry,
  DN.Types,
  DN.PackageProvider.GitHub,
  DN.PackageProvider.Installed,
  Delphinus.SetupDialog,
  DN.Compiler.Intf,
  DN.Compiler.MSBuild,
  DN.Installer.Intf,
  DN.Installer.IDE,
  DN.Uninstaller.Intf,
  DN.Uninstaller.IDE,
  DN.Setup,
  Delphinus.OptionsDialog;

{$R *.dfm}

const
  CDelphinusSubKey = 'Delphinus';
  COAuthTokenKey = 'OAuthToken';

{ TDelphinusDialog }

procedure TDelphinusDialog.actOptionsExecute(Sender: TObject);
var
  LDialog: TDelphinusOptionsDialog;
begin
  LDialog := TDelphinusOptionsDialog.Create(nil);
  try
    LDialog.Settings := FSettings;
    if LDialog.ShowModal = mrOk then
    begin
      FSettings := LDialog.Settings;
      SaveSettings(FSettings);
      RecreatePackageProvider();
    end;
  finally
    LDialog.Free;
  end;
end;

procedure TDelphinusDialog.actRefreshExecute(Sender: TObject);
begin
  TThread.CreateAnonymousThread(
    procedure
    begin
      if FPackageProvider.Reload() then
      begin
        FPackages.Clear;
        FPackages.AddRange(FPackageProvider.Packages);
      end;
      TThread.Queue(nil,
        procedure
        begin
          FCategoryFilteView.OnlineCount := FPackages.Count;
          RefreshInstalledPackages();
          FProgressDialog.ModalResult := mrOk;
        end);
    end).Start;
  FProgressDialog.Caption := 'Delphinus';
  FProgressDialog.Task := 'Refreshing';
  FProgressDialog.Progress := -1;
  FProgressDialog.ShowModal();
end;

procedure TDelphinusDialog.btnInstallFolderClick(Sender: TObject);
var
  LDialog: TSetupDialog;
begin
  if dlgSelectInstallFile.Execute() then
  begin
    LDialog := TSetupDialog.Create(CreateSetup());
    try
      LDialog.ExecuteInstallationFromDirectory(ExtractFilePath(dlgSelectInstallFile.FileName));
    finally
      LDialog.Free;
    end;
    RefreshInstalledPackages();
  end;
end;

procedure TDelphinusDialog.btnUninstallClick(Sender: TObject);
var
  LDialog: TSetupDialog;
begin
  if dlgSelectUninstallFile.Execute() then
  begin
    LDialog := TSetupDialog.Create(CreateSetup());
    try
      LDialog.ExecuteUninstallationFromDirectory(ExtractFilePath(dlgSelectUninstallFile.FileName));
    finally
      LDialog.Free;
    end;
    RefreshInstalledPackages();
  end;
end;

constructor TDelphinusDialog.Create(AOwner: TComponent);
begin
  inherited;
  FProgressDialog := TProgressDialog.Create(Self);
  FDetailView := TPackageDetailView.Create(Self);
  FDetailView.Align := alClient;
  FDetailView.Visible := False;
  FDetailView.Parent := Self;

  FOverView := TPackageOverView.Create(Self);
  FOverView.Align := alClient;
  FOverView.AlignWithMargins := True;
  FOverView.Parent := Self;
  FOverView.OnCheckIsPackageInstalled := GetInstalledVersion;
  FOverView.OnCheckHasPackageUpdate := GetUpdateVersion;
  FOverView.OnInstallPackage :=  InstallPackage;
  FOverView.OnUninstallPackage := UninstallPackage;
  FOverView.OnUpdatePackage := UpdatePackage;
  FOverView.OnInfoPackage := ShowDetail;
  FOverView.DoubleBuffered := True;

  FCategoryFilteView := TCategoryFilterView.Create(Self);
  FCategoryFilteView.Width := 200;
  FCategoryFilteView.Align := alLeft;
  FCategoryFilteView.AlignWithMargins := True;
  FCategoryFilteView.Margins.Left := 0;
  FCategoryFilteView.Margins.Bottom := 0;
  FCategoryFilteView.OnCategoryChanged := HandleCategoryChanged;
  FCategoryFilteView.Parent := Self;

  FPackages := TList<IDNPackage>.Create();
  FInstalledPackages := TList<IDNPackage>.Create();
  FUpdatePackages := TList<IDNPackage>.Create();
  LoadSettings(FSettings);
  RecreatePackageProvider();
  FInstalledPackageProvider := TDNInstalledPackageProvider.Create(GetComponentDirectory());
  RefreshInstalledPackages();
  dlgSelectInstallFile.Filter := CInstallFileFilter;
  dlgSelectUninstallFile.Filter := CUninstallFileFilter;
end;

function TDelphinusDialog.CreateSetup: IDNSetup;
var
  LCompiler: IDNCompiler;
  LInstaller: IDNInstaller;
  LUninstaller: IDNUninstaller;
begin
  LCompiler := TDNMSBuildCompiler.Create(GetEnvironmentVariable('BDSBIN'));
  LCompiler.BPLOutput := GetBPLDirectory();
  LCompiler.DCPOutput := GetDCPDirectory();
  LInstaller := TDNIDEInstaller.Create(LCompiler, Trunc(CompilerVersion));
  LUninstaller := TDNIDEUninstaller.Create();
  Result := TDNSetup.Create(LInstaller, LUninstaller, FPackageProvider);
  Result.ComponentDirectory := GetComponentDirectory();
end;

destructor TDelphinusDialog.Destroy;
begin
  FOverView.OnSelectedPackageChanged := nil;
//  FInstalledOverview.OnSelectedPackageChanged := nil;
  FPackages.Free;
  FInstalledPackages.Free;
  FUpdatePackages.Free;
  FPackageProvider := nil;
  FInstalledPackageProvider := nil;
  inherited;
end;

procedure TDelphinusDialog.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  LPos: TPoint;
  LOverView: TPackageOverView;
begin
  LOverView := GetActiveOverView();
  LPos := LOverView.ScreenToClient(MousePos);
  if PtInRect(Rect(0, 0, LOverView.Width, LOverView.Height), LPos) then
  begin
    LOverView.VertScrollBar.Position := LOverView.VertScrollBar.Position - WheelDelta;
    Handled := True;
  end;
end;

function TDelphinusDialog.GetActiveOverView: TPackageOverView;
begin
  Result := FOverView;
end;

function TDelphinusDialog.GetActivePackageSource: TList<IDNPackage>;
begin
  case FCategory of
    pcOnline: Result := FPackages;
    pcInstalled: Result := FInstalledPackages;
    pcUpdates: Result := FUpdatePackages;
  else
    Result := FPackages;
  end;
end;

function TDelphinusDialog.GetBPLDirectory: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('BDSCOMMONDIR'), 'Bpl');
end;

function TDelphinusDialog.GetComponentDirectory: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('BDSCOMMONDIR'), 'Comps');
end;

function TDelphinusDialog.GetDCPDirectory: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('BDSCOMMONDIR'), 'Dcp');
end;

function TDelphinusDialog.GetInstalledPackage(
  const APackage: IDNPackage): IDNPackage;
var
  LPackage: IDNPackage;
begin
  Result := nil;
  if Assigned(APackage) then
  begin
    for LPackage in FInstalledPackages do
    begin
      if LPackage.ID = APackage.ID then
        Exit(LPackage);
    end;
  end
end;

function TDelphinusDialog.GetInstalledVersion(
  const APackage: IDNPackage): string;
var
  LPackage: IDNPackage;
begin
  Result := '';
  LPackage := GetInstalledPackage(APackage);
  if Assigned(LPackage) then
  begin
    if LPackage.Versions.Count > 0 then
      Result := LPackage.Versions[0].Name
    else
      Result := 'none';
  end;
end;

function TDelphinusDialog.GetOverviewPackage(
  const APackage: IDNPackage): IDNPackage;
var
  LPackage: IDNPackage;
begin
  Result := nil;
  if Assigned(APackage) then
  begin
    for LPackage in FPackages do
    begin
      if LPackage.ID = APackage.ID then
        Exit(LPackage);
    end;
  end
end;

function TDelphinusDialog.GetUpdateVersion(const APackage: IDNPackage): string;
var
  LVersion: string;
  LPackage: IDNPackage;
begin
  Result := '';
  LVersion := GetInstalledVersion(APackage);
  LPackage := GetOverviewPackage(APackage);
  if Assigned(LPackage) and (LVersion <> '') then
  begin
    if (LPackage.Versions.Count > 0) and (LPackage.Versions[0].Name <> LVersion) then
      Result := LPackage.Versions[0].Name;
  end;
end;

procedure TDelphinusDialog.HandleCategoryChanged(Sender: TObject;
  ANewCategory: TPackageCategory);
begin
  FCategory := ANewCategory;
  RefreshOverview();
end;

procedure TDelphinusDialog.InstallPackage(const APackage: IDNPackage);
var
  LDialog: TSetupDialog;
begin
  if Assigned(APackage) then
  begin
    LDialog := TSetupDialog.Create(CreateSetup());
    try
      LDialog.ExecuteInstallation(APackage);
    finally
      LDialog.Free;
    end;
    RefreshInstalledPackages();
  end;
end;

function TDelphinusDialog.IsPackageInstalled(
  const APackage: IDNPackage): Boolean;
begin
  Result := Assigned(GetInstalledPackage(APackage));
end;

procedure TDelphinusDialog.LoadSettings(out ASettings: TDelphinusSettings);
var
  LRegistry: TRegistry;
  LBase: string;
begin
  LRegistry := TRegistry.Create();
  try
    LBase := (BorlandIDEServices as IOTAServices).GetBaseRegistryKey();
    LRegistry.RootKey := HKEY_CURRENT_USER;
    if LRegistry.OpenKey(TPath.Combine(LBase, CDelphinusSubKey), False) then
    begin
      FSettings.OAuthToken := LRegistry.ReadString(COAuthTokenKey);
    end;
  finally
    LRegistry.Free;
  end;
end;

procedure TDelphinusDialog.RecreatePackageProvider;
begin
  FPackageProvider := TDNGitHubPackageProvider.Create(FSettings.OAuthToken);
end;

procedure TDelphinusDialog.RefreshInstalledPackages;
var
  LInstalledPackage: IDNPackage;
begin
  if FInstalledPackageProvider.Reload() then
  begin
    FInstalledPackages.Clear;
    FInstalledPackages.AddRange(FInstalledPackageProvider.Packages);
    FCategoryFilteView.InstalledCount := FInstalledPackages.Count;
    FUpdatePackages.Clear();
    for LInstalledPackage in FInstalledPackages do
    begin
      if GetUpdateVersion(LInstalledPackage) <> '' then
        FUpdatePackages.Add(LInstalledPackage);
    end;
    FCategoryFilteView.UpdatesCount := FUpdatePackages.Count;
  end;
  RefreshOverview();
end;

procedure TDelphinusDialog.RefreshOverview;
begin
  GetActiveOverView().Clear;
  GetActiveOverView().Packages.AddRange(GetActivePackageSource());
  FDetailView.Visible := False;
end;

procedure TDelphinusDialog.SaveSettings(const ASettings: TDelphinusSettings);
var
  LRegistry: TRegistry;
  LBase: string;
begin
  LRegistry := TRegistry.Create();
  try
    LBase := (BorlandIDEServices as IOTAServices).GetBaseRegistryKey();
    LRegistry.RootKey := HKEY_CURRENT_USER;
    if LRegistry.OpenKey(TPath.Combine(LBase, CDelphinusSubKey), True) then
    begin
      LRegistry.WriteString(COAuthTokenKey, FSettings.OAuthToken);
    end;
  finally
    LRegistry.Free;
  end;
end;

procedure TDelphinusDialog.ShowDetail(const APackage: IDNPackage);
begin
  FDetailView.Package := APackage;
  FDetailView.BringToFront();
  FDetailView.Visible := True;
end;

procedure TDelphinusDialog.UnInstallPackage(const APackage: IDNPackage);
var
  LDialog: TSetupDialog;
begin
  if Assigned(APackage) then
  begin
    LDialog := TSetupDialog.Create(CreateSetup());
    try
      LDialog.ExecuteUninstallation(APackage);
    finally
      LDialog.Free;
    end;
    RefreshInstalledPackages();
  end;
end;

procedure TDelphinusDialog.UpdatePackage(const APackage: IDNPackage);
var
  LDialog: TSetupDialog;
begin
  if Assigned(APackage) then
  begin
    LDialog := TSetupDialog.Create(CreateSetup());
    try
      LDialog.ExecuteUpdate(APackage);
    finally
      LDialog.Free;
    end;
    RefreshInstalledPackages();
  end;
end;

end.
