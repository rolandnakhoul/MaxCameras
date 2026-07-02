/* CameraMax.ms - consolidated, validated script
   - Placeholders at startup (no blocking captures)
   - Timer-driven thumbnail refresh (one camera per tick)
   - Excludes camera target nodes
   - Hides camera target while capturing and restores it
   - Safe image loading via MemoryStream to avoid file locks
   - Global dotNet handlers only (no closures capturing locals)
   - Export, Flip H/V, Search, Rename, Overlay support
   - Status progress while refreshing
*/

global CameraMax_Rows
global CameraMax_Entries
global CameraMax_OverlayOn = false
global CameraMax_OverlayMode = "thirds"

-- UI globals
global CM_Form CM_BodyPanel CM_SearchBox CM_AddRowBtn CM_RefreshBtn CM_ExportBtn CM_StatusLabel
global CM_OverlayChk CM_OverlayCombo CM_FlipHBtn CM_FlipVBtn CM_CtxMenu CM_MiRefresh CM_MiRename CM_MiColor
global CM_CtxTargetCam CM_RowYPos

-- runtime globals
global CM_RefreshTimer CM_RefreshQueueIndex CM_RefreshRunning
global CM_RenameCam CM_RenameLabel CM_RenameTextBox CM_NewRowTextBox

struct CamRowData (rowName, rowColor, groupBox, flowPanel)
struct CamEntryData (cam, picBox, nameLabel, tempFile)

-- Helpers: userprop accessors
fn CM_GetProp cam key defaultVal =
(
    local v = undefined
    try ( v = getUserProp cam key ) catch()
    if v == undefined then defaultVal else v
)
fn CM_SetProp cam key val = ( try ( setUserProp cam key val ) catch() )

fn CM_GetRow cam = CM_GetProp cam "CM_Row" "Cameras"
fn CM_GetOutW cam = CM_GetProp cam "CM_OutW" (renderWidth as string)
fn CM_GetOutH cam = CM_GetProp cam "CM_OutH" (renderHeight as string)
fn CM_GetFlipH cam = CM_GetProp cam "CM_FlipH" "0"
fn CM_GetFlipV cam = CM_GetProp cam "CM_FlipV" "0"

-- Safe temp filename
fn CM_TempThumbPath camName =
(
    local safe = (filterString camName " :\\/*?\"<>|")[1]
    (getDir #temp) + "\\CameraMax_" + safe + ".jpg"
)

-- Safe load of bitmap via MemoryStream (prevents file lock)
fn CM_LoadBitmapFile filepath =
(
    try
    (
        if not (doesFileExist filepath) then return undefined
        local fileIO = dotNetClass "System.IO.File"
        local bytes = fileIO.ReadAllBytes filepath
        local ms = dotNetObject "System.IO.MemoryStream" bytes
        local bmpSrc = dotNetObject "System.Drawing.Bitmap" ms
        local bmp = dotNetObject "System.Drawing.Bitmap" bmpSrc
        try ( bmpSrc.Dispose() ) catch()
        try ( ms.Close() ) catch()
        bmp
    ) catch ( undefined )
)

-- Safely set a PictureBox image, disposing previous image
fn CM_SetPictureBoxImage pic bmp =
(
    try
    (
        if pic.Image != undefined then
        (
            try ( pic.Image.Dispose() ) catch()
            pic.Image = undefined
        )
    ) catch()
    if bmp != undefined then pic.Image = bmp
)

-- Collect cameras excluding any node that is a .target of another camera
fn CM_CollectCameras =
(
    local cams = #()
    local candidates = for o in objects where isKindOf o camera collect o
    for o in candidates do
    (
        local isTarget = false
        for c in cameras where c != o do
        (
            try
            (
                if isProperty c "target" and c.target == o then
                (
                    isTarget = true
                    exit
                )
            ) catch()
        )
        if not isTarget then append cams o
    )
    cams
)

-- Capture a camera viewport to a temp JPG, hide target while capturing, restore state.
fn CM_CaptureThumb cam w:160 h:110 =
(
    local outFile = CM_TempThumbPath cam.name
    local ok = true
    local prevCam = undefined
    local prevType = undefined
    local tgt = undefined
    local tgtWasHidden = undefined

    try
    (
        if isProperty cam "target" then tgt = (try (cam.target) catch undefined)
        if tgt != undefined then tgtWasHidden = (try (isHidden tgt) catch undefined)

        prevType = (try (viewport.getType()) catch undefined)
        prevCam  = (try (viewport.getCamera()) catch undefined)

        if tgt != undefined and tgtWasHidden == false then try ( hide tgt ) catch()

        viewport.setType #view_camera
        viewport.setCamera cam
        redrawViews(); completeRedraw()
        sleep 60

        local dib = gw.getViewportDib()
        if dib != undefined then
        (
            local bmp = bitmap w h color:(color 20 20 20)
            copy dib bmp
            save bmp filename:outFile quality:85
            close dib; close bmp
        )
        else ok = false
    ) catch ( ok = false )

    -- restore viewport/camera
    try
    (
        if prevCam != undefined then viewport.setCamera prevCam
        if prevType != undefined then viewport.setType prevType
        redrawViews(); completeRedraw()
    ) catch()

    -- restore target visibility
    if tgt != undefined and tgtWasHidden != undefined then
    (
        try
        (
            if tgtWasHidden == false then show tgt
            else if tgtWasHidden == true then hide tgt
        ) catch()
    )

    if ok then
    (
        -- optional flip adjustments stored in userprops
        try
        (
            local flipH = ((CM_GetFlipH cam) as integer) == 1
            local flipV = ((CM_GetFlipV cam) as integer) == 1
            if (flipH or flipV) and (doesFileExist outFile) then
            (
                local bmpDot = dotNetObject "System.Drawing.Bitmap" outFile
                local rf = dotNetClass "System.Drawing.RotateFlipType"
                if flipH and flipV then bmpDot.RotateFlip rf.RotateNoneFlipXY
                else if flipH then bmpDot.RotateFlip rf.RotateNoneFlipX
                else bmpDot.RotateFlip rf.RotateNoneFlipY
                bmpDot.Save outFile
                bmpDot.Dispose()
            )
        ) catch()
        outFile
    )
    else undefined
)

-- UI row creation
fn CM_AddRowUI rowName rowColor =
(
    local grp = dotNetObject "System.Windows.Forms.GroupBox"
    grp.Text = rowName
    grp.ForeColor = CM_ColorCls.FromArgb rowColor.r rowColor.g rowColor.b
    grp.Location = dotNetObject "System.Drawing.Point" 0 CM_RowYPos
    grp.Size = dotNetObject "System.Drawing.Size" 590 170

    local flow = dotNetObject "System.Windows.Forms.FlowLayoutPanel"
    flow.Location = dotNetObject "System.Drawing.Point" 8 20
    flow.Size = dotNetObject "System.Drawing.Size" 570 140
    flow.AutoScroll = true
    flow.BackColor = CM_ColorCls.FromArgb 60 60 63

    grp.Controls.Add flow
    CM_BodyPanel.Controls.Add grp

    CM_RowYPos += 180
    local rd = CamRowData rowName:rowName rowColor:rowColor groupBox:grp flowPanel:flow
    append CameraMax_Rows rd
    rd
)

-- Add camera placeholder entry to UI (no capture)
fn CM_AddCameraUI cam =
(
    local rowName = CM_GetRow cam
    local rowData = undefined
    for r in CameraMax_Rows where r.rowName == rowName do rowData = r
    if rowData == undefined then rowData = CM_AddRowUI rowName (color 100 180 220)

    local outer = dotNetObject "System.Windows.Forms.Panel"
    outer.Size = dotNetObject "System.Drawing.Size" 140 130
    outer.Margin = dotNetObject "System.Windows.Forms.Padding" 4

    local pic = dotNetObject "System.Windows.Forms.PictureBox"
    pic.Size = dotNetObject "System.Drawing.Size" 140 100
    pic.SizeMode = CM_PBSizeMode.StretchImage
    pic.BorderStyle = CM_BorderStyleCls.FixedSingle
    outer.Controls.Add pic

    local lbl = dotNetObject "System.Windows.Forms.Label"
    lbl.Text = cam.name
    lbl.ForeColor = CM_ColorCls.FromArgb 210 210 210
    lbl.Location = dotNetObject "System.Drawing.Point" 0 102
    lbl.Size = dotNetObject "System.Drawing.Size" 140 26
    lbl.TextAlign = CM_ContentAlignCls.TopCenter
    outer.Controls.Add lbl

    local ed = CamEntryData cam:cam picBox:pic nameLabel:lbl tempFile:undefined
    append CameraMax_Entries ed

    -- wire to global handlers (no closure)
    dotNet.addEventHandler pic "Click" CM_OnPicClick
    dotNet.addEventHandler pic "DoubleClick" CM_OnPicDblClick
    dotNet.addEventHandler pic "MouseDown" CM_OnPicMouseDown

    rowData.flowPanel.Controls.Add outer
    ed
)

-- Populate UI with placeholders
fn CM_PopulateAll =
(
    for r in CameraMax_Rows do CM_BodyPanel.Controls.Remove r.groupBox
    CameraMax_Rows = #()
    CameraMax_Entries = #()
    CM_RowYPos = 0

    local cams = CM_CollectCameras()
    for c in cams do CM_AddCameraUI c

    CM_StatusLabel.Text = (cams.count as string) + " cameras"
)

-- Find entry by picturebox control
fn CM_FindEntryByControl ctrl =
(
    local found = undefined
    for ed in CameraMax_Entries where ed.picBox == ctrl do found = ed
    found
)

-- Handlers for picturebox events
fn CM_OnPicClick sender e =
(
    local ed = CM_FindEntryByControl sender
    if ed != undefined then
    (
        viewport.setCamera ed.cam
        completeRedraw()
        renderWidth = (CM_GetOutW ed.cam) as integer
        renderHeight = (CM_GetOutH ed.cam) as integer
    )
)

fn CM_OnPicDblClick sender e =
(
    local ed = CM_FindEntryByControl sender
    if ed != undefined then CM_RenameCamera ed.cam ed.nameLabel
)

fn CM_OnPicMouseDown sender e =
(
    local ed = CM_FindEntryByControl sender
    if ed != undefined and e.Button == CM_MouseButtonsCls.Right then
    (
        CM_CtxTargetCam = ed.cam
        CM_CtxMenu.Show sender e.Location
    )
)

-- Rename dialog
fn CM_OnRenameOk s e =
(
    if CM_RenameTextBox.Text != "" then
    (
        CM_RenameCam.name = CM_RenameTextBox.Text
        CM_RenameLabel.Text = CM_RenameTextBox.Text
    )
    (s.FindForm()).Close()
)

fn CM_RenameCamera cam lbl =
(
    CM_RenameCam = cam
    CM_RenameLabel = lbl
    local dlg = dotNetObject "System.Windows.Forms.Form"
    dlg.Text = "Rename Camera"
    dlg.Size = dotNetObject "System.Drawing.Size" 300 120
    dlg.StartPosition = CM_FormStartPos.CenterScreen

    CM_RenameTextBox = dotNetObject "System.Windows.Forms.TextBox"
    CM_RenameTextBox.Text = cam.name
    CM_RenameTextBox.Location = dotNetObject "System.Drawing.Point" 10 15
    CM_RenameTextBox.Size = dotNetObject "System.Drawing.Size" 260 24
    dlg.Controls.Add CM_RenameTextBox

    local okBtn = dotNetObject "System.Windows.Forms.Button"
    okBtn.Text = "OK"
    okBtn.Location = dotNetObject "System.Drawing.Point" 100 50
    dotNet.addEventHandler okBtn "Click" CM_OnRenameOk
    dlg.Controls.Add okBtn

    dlg.ShowDialog()
)

-- Refresh queue control (timer)
fn CM_StartRefreshQueue =
(
    try ( if CM_RefreshTimer != undefined then CM_StopRefreshQueue() ) catch()
    CM_RefreshQueueIndex = 1
    CM_RefreshRunning = true
    CM_RefreshTimer = dotNetObject "System.Windows.Forms.Timer"
    CM_RefreshTimer.Interval = 120
    dotNet.addEventHandler CM_RefreshTimer "Tick" CM_RefreshTimer_Tick
    CM_RefreshBtn.Text = "Cancel"
    CM_RefreshTimer.Start()
)

fn CM_StopRefreshQueue =
(
    try
    (
        if CM_RefreshTimer != undefined then
        (
            CM_RefreshTimer.Stop()
            dotNet.removeEventHandler CM_RefreshTimer "Tick" CM_RefreshTimer_Tick
            CM_RefreshTimer.Dispose()
            CM_RefreshTimer = undefined
        )
    ) catch()
    CM_RefreshRunning = false
    CM_RefreshBtn.Text = "Refresh thumbnails"
    CM_StatusLabel.Text = (CameraMax_Entries.count as string) + " cameras"
)

fn CM_RefreshTimer_Tick sender e =
(
    try
    (
        if CM_RefreshQueueIndex > CameraMax_Entries.count then
        (
            CM_StopRefreshQueue()
            return
        )

        local ed = CameraMax_Entries[CM_RefreshQueueIndex]
        if ed != undefined then
        (
            local f = undefined
            try ( f = CM_CaptureThumb ed.cam w:160 h:110 ) catch()
            if f != undefined and (doesFileExist f) then
            (
                local bmp = CM_LoadBitmapFile f
                CM_SetPictureBoxImage ed.picBox bmp
                ed.tempFile = f
            )
        )

        CM_StatusLabel.Text = (CM_RefreshQueueIndex as string) + " / " + (CameraMax_Entries.count as string) + " thumbnails"
        CM_RefreshQueueIndex += 1
    ) catch
    (
        CM_StopRefreshQueue()
    )
)

-- Context menu handlers
fn CM_OnMiRefreshClick sender e =
(
    if CM_CtxTargetCam != undefined then
    (
        local f = CM_CaptureThumb CM_CtxTargetCam w:160 h:110
        for ed in CameraMax_Entries where ed.cam == CM_CtxTargetCam do
        (
            if f != undefined and (doesFileExist f) then
            (
                local bmp = CM_LoadBitmapFile f
                CM_SetPictureBoxImage ed.picBox bmp
                ed.tempFile = f
            )
        )
    )
)

fn CM_OnMiRenameClick sender e =
(
    if CM_CtxTargetCam != undefined then
    (
        for ed in CameraMax_Entries where ed.cam == CM_CtxTargetCam do CM_RenameCamera CM_CtxTargetCam ed.nameLabel
    )
)

fn CM_OnMiColorClick sender e =
(
    if CM_CtxTargetCam != undefined then
    (
        local dlgColor = dotNetObject "System.Windows.Forms.ColorDialog"
        if dlgColor.ShowDialog() == CM_DialogResultCls.OK then
        (
            local rowName = CM_GetRow CM_CtxTargetCam
            for r in CameraMax_Rows where r.rowName == rowName do r.groupBox.ForeColor = dlgColor.Color
        )
    )
)

fn CM_OnFormClosed sender e =
(
    CM_ToggleOverlay false
    try ( CM_StopRefreshQueue() ) catch()
)

-- Export all thumbnails
fn CM_ExportAllThumbs sender e =
(
    local dlg = dotNetObject "System.Windows.Forms.FolderBrowserDialog"
    if dlg.ShowDialog() == CM_DialogResultCls.OK then
    (
        local outFolder = dlg.SelectedPath
        local fileIO = dotNetClass "System.IO.File"
        local cams = CM_CollectCameras()
        for c in cams do
        (
            local f = CM_CaptureThumb c w:320 h:240
            if f != undefined and (doesFileExist f) then
            (
                local safeName = (filterString c.name " :\\/*?\"<>|")[1]
                local dest = outFolder + "\\" + safeName + ".jpg"
                try ( fileIO.Copy f dest true ) catch()
            )
        )
        (dotNetClass "System.Windows.Forms.MessageBox").Show ("Saved thumbnails to: " + outFolder)
    )
)

-- Overlay draw helpers
fn CM_ln x1 y1 x2 y2 = ( gw.polyline #([x1,y1,0],[x2,y2,0]) false )

fn CM_DrawGuides =
(
    if not CameraMax_OverlayOn then return OK
    local vs = getViewSize()
    local vpW = vs.x
    local vpH = vs.y
    gw.setTransform (matrix3 1)
    gw.setColor #line (color 255 255 255)

    case CameraMax_OverlayMode of
    (
        "thirds": (
            CM_ln (vpW/3.0) 0 (vpW/3.0) vpH
            CM_ln (vpW*2.0/3.0) 0 (vpW*2.0/3.0) vpH
            CM_ln 0 (vpH/3.0) vpW (vpH/3.0)
            CM_ln 0 (vpH*2.0/3.0) vpW (vpH*2.0/3.0)
        )
        "golden": (
            local g = 0.382
            CM_ln (vpW*g) 0 (vpW*g) vpH
            CM_ln (vpW*(1-g)) 0 (vpW*(1-g)) vpH
            CM_ln 0 (vpH*g) vpW (vpH*g)
            CM_ln 0 (vpH*(1-g)) vpW (vpH*(1-g))
        )
        "triangle": (
            CM_ln 0 0 vpW vpH
            CM_ln 0 vpH vpW 0
        )
        default: ()
    )

    gw.enlargeUpdateRect #whole
    gw.updateScreen()
    OK
)

fn CM_ToggleOverlay state =
(
    CameraMax_OverlayOn = state
    if state then registerRedrawViewsCallback CM_DrawGuides
    else unregisterRedrawViewsCallback CM_DrawGuides
    completeRedraw()
)

-- Build UI
fn CM_BuildUI =
(
    try ( if CM_Form != undefined then ( CM_Form.Close(); CM_Form = undefined ) ) catch()

    CameraMax_Rows = #()
    CameraMax_Entries = #()
    CM_RowYPos = 0
    CM_RefreshTimer = undefined
    CM_RefreshRunning = false

    CM_ColorCls = dotNetClass "System.Drawing.Color"
    CM_PBSizeMode = dotNetClass "System.Windows.Forms.PictureBoxSizeMode"
    CM_BorderStyleCls = dotNetClass "System.Windows.Forms.BorderStyle"
    CM_ContentAlignCls = dotNetClass "System.Drawing.ContentAlignment"
    CM_MouseButtonsCls = dotNetClass "System.Windows.Forms.MouseButtons"
    CM_FormStartPos = dotNetClass "System.Windows.Forms.FormStartPosition"
    CM_DialogResultCls = dotNetClass "System.Windows.Forms.DialogResult"

    CM_Form = dotNetObject "System.Windows.Forms.Form"
    CM_Form.Text = "CameraMax v1.0"
    CM_Form.Size = dotNetObject "System.Drawing.Size" 640 760
    CM_Form.StartPosition = CM_FormStartPos.Manual
    CM_Form.Location = dotNetObject "System.Drawing.Point" 200 200
    CM_Form.BackColor = CM_ColorCls.FromArgb 45 45 48

    CM_SearchBox = dotNetObject "System.Windows.Forms.TextBox"
    CM_SearchBox.Location = dotNetObject "System.Drawing.Point" 10 10
    CM_SearchBox.Size = dotNetObject "System.Drawing.Size" 400 24
    CM_Form.Controls.Add CM_SearchBox

    local searchLabel = dotNetObject "System.Windows.Forms.Label"
    searchLabel.Text = "Search cameras..."
    searchLabel.ForeColor = CM_ColorCls.FromArgb 160 160 160
    searchLabel.Location = dotNetObject "System.Drawing.Point" 415 14
    searchLabel.Size = dotNetObject "System.Drawing.Size" 100 20
    CM_Form.Controls.Add searchLabel

    CM_AddRowBtn = dotNetObject "System.Windows.Forms.Button"
    CM_AddRowBtn.Text = "+ Add row"
    CM_AddRowBtn.Location = dotNetObject "System.Drawing.Point" 520 8
    CM_AddRowBtn.Size = dotNetObject "System.Drawing.Size" 100 26
    CM_Form.Controls.Add CM_AddRowBtn

    CM_BodyPanel = dotNetObject "System.Windows.Forms.Panel"
    CM_BodyPanel.Location = dotNetObject "System.Drawing.Point" 10 42
    CM_BodyPanel.Size = dotNetObject "System.Drawing.Size" 610 560
    CM_BodyPanel.AutoScroll = true
    CM_BodyPanel.BackColor = CM_ColorCls.FromArgb 45 45 48
    CM_Form.Controls.Add CM_BodyPanel

    CM_OverlayChk = dotNetObject "System.Windows.Forms.CheckBox"
    CM_OverlayChk.Text = "Overlay"
    CM_OverlayChk.ForeColor = CM_ColorCls.FromArgb 220 220 220
    CM_OverlayChk.Location = dotNetObject "System.Drawing.Point" 150 613
    CM_OverlayChk.Size = dotNetObject "System.Drawing.Size" 75 24
    CM_Form.Controls.Add CM_OverlayChk

    CM_OverlayCombo = dotNetObject "System.Windows.Forms.ComboBox"
    CM_OverlayCombo.Location = dotNetObject "System.Drawing.Point" 230 610
    CM_OverlayCombo.Size = dotNetObject "System.Drawing.Size" 130 24
    CM_OverlayCombo.Items.Add "No overlay"
    CM_OverlayCombo.Items.Add "Rule of thirds"
    CM_OverlayCombo.Items.Add "Golden ratio"
    CM_OverlayCombo.Items.Add "Golden triangle"
    CM_OverlayCombo.SelectedIndex = 0
    CM_Form.Controls.Add CM_OverlayCombo

    CM_FlipHBtn = dotNetObject "System.Windows.Forms.Button"
    CM_FlipHBtn.Text = "Flip H"
    CM_FlipHBtn.Location = dotNetObject "System.Drawing.Point" 370 610
    CM_FlipHBtn.Size = dotNetObject "System.Drawing.Size" 60 26
    CM_Form.Controls.Add CM_FlipHBtn

    CM_FlipVBtn = dotNetObject "System.Windows.Forms.Button"
    CM_FlipVBtn.Text = "Flip V"
    CM_FlipVBtn.Location = dotNetObject "System.Drawing.Point" 435 610
    CM_FlipVBtn.Size = dotNetObject "System.Drawing.Size" 60 26
    CM_Form.Controls.Add CM_FlipVBtn

    CM_RefreshBtn = dotNetObject "System.Windows.Forms.Button"
    CM_RefreshBtn.Text = "Refresh thumbnails"
    CM_RefreshBtn.Location = dotNetObject "System.Drawing.Point" 10 645
    CM_RefreshBtn.Size = dotNetObject "System.Drawing.Size" 150 26
    CM_Form.Controls.Add CM_RefreshBtn

    CM_ExportBtn = dotNetObject "System.Windows.Forms.Button"
    CM_ExportBtn.Text = "Export Thumbs"
    CM_ExportBtn.Location = dotNetObject "System.Drawing.Point" 520 645
    CM_ExportBtn.Size = dotNetObject "System.Drawing.Size" 100 26
    CM_Form.Controls.Add CM_ExportBtn

    CM_StatusLabel = dotNetObject "System.Windows.Forms.Label"
    CM_StatusLabel.Text = "0 cameras"
    CM_StatusLabel.ForeColor = CM_ColorCls.FromArgb 160 160 160
    CM_StatusLabel.Location = dotNetObject "System.Drawing.Point" 170 649
    CM_StatusLabel.Size = dotNetObject "System.Drawing.Size" 300 20
    CM_Form.Controls.Add CM_StatusLabel

    CM_CtxMenu = dotNetObject "System.Windows.Forms.ContextMenuStrip"
    CM_MiRefresh = dotNetObject "System.Windows.Forms.ToolStripMenuItem"
    CM_MiRename = dotNetObject "System.Windows.Forms.ToolStripMenuItem"
    CM_MiColor = dotNetObject "System.Windows.Forms.ToolStripMenuItem"
    CM_MiRefresh.Text = "Refresh thumbnail"
    CM_MiRename.Text = "Rename..."
    CM_MiColor.Text = "Set row color..."
    CM_CtxMenu.Items.Add CM_MiRefresh
    CM_CtxMenu.Items.Add CM_MiRename
    CM_CtxMenu.Items.Add CM_MiColor

    -- wire events to global functions
    dotNet.addEventHandler CM_AddRowBtn "Click" CM_OnAddRowClick
    dotNet.addEventHandler CM_RefreshBtn "Click" CM_OnRefreshClick
    dotNet.addEventHandler CM_ExportBtn "Click" CM_ExportAllThumbs
    dotNet.addEventHandler CM_OverlayChk "CheckedChanged" CM_OnOverlayChkChanged
    dotNet.addEventHandler CM_OverlayCombo "SelectedIndexChanged" CM_OnOverlayComboChanged
    dotNet.addEventHandler CM_FlipHBtn "Click" CM_OnFlipHClick
    dotNet.addEventHandler CM_FlipVBtn "Click" CM_OnFlipVClick
    dotNet.addEventHandler CM_SearchBox "TextChanged" CM_OnSearchChanged
    dotNet.addEventHandler CM_MiRefresh "Click" CM_OnMiRefreshClick
    dotNet.addEventHandler CM_MiRename "Click" CM_OnMiRenameClick
    dotNet.addEventHandler CM_MiColor "Click" CM_OnMiColorClick
    dotNet.addEventHandler CM_Form "FormClosed" CM_OnFormClosed

    CM_PopulateAll()
    CM_Form.Show()
)

-- initialize
CM_BuildUI()

macroScript CameraMax_Open
category:"CameraMax"
buttonText:"CameraMax"
tooltip:"Open CameraMax camera manager"
(
    on execute do CM_BuildUI()
)
