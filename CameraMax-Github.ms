/* CameraMax.ms - final corrected, stable CameraMax
   - Placeholder UI at startup (no blocking captures)
   - Timer-driven thumbnail refresh (one camera per tick)
   - Excludes camera target nodes from the list
   - Hides camera target while capturing and restores it
   - Loads images with MemoryStream to avoid file locks
   - No anonymous handlers that capture outer locals (uses global handlers)
   - Export Thumbs, Flip H/V, Search, Rename, Overlay support
   - Progress indicator in status label while refreshing
*/

global CameraMax_Rows
global CameraMax_Entries
global CameraMax_OverlayOn = false
global CameraMax_OverlayMode = "thirds"

global CM_ColorCls
global CM_PBSizeMode
global CM_BorderStyleCls
global CM_ContentAlignCls
global CM_MouseButtonsCls
global CM_FormStartPos
global CM_DialogResultCls

global CM_Form
global CM_BodyPanel
global CM_SearchBox
global CM_AddRowBtn
global CM_RefreshBtn
global CM_ExportBtn
global CM_StatusLabel
global CM_OverlayChk
global CM_OverlayCombo
global CM_FlipHBtn
global CM_FlipVBtn
global CM_CtxMenu
global CM_MiRefresh
global CM_MiRename
global CM_MiColor
global CM_CtxTargetCam
global CM_RowYPos

global CM_RefreshTimer
global CM_RefreshQueueIndex
global CM_RefreshRunning

global CM_RenameCam
global CM_RenameLabel
global CM_RenameTextBox
global CM_NewRowTextBox

struct CamRowData (rowName, rowColor, groupBox, flowPanel)
struct CamEntryData (cam, picBox, nameLabel, tempFile)

-- forward-declare functions used across the script
global CM_TempThumbPath, CM_GetProp, CM_SetProp, CM_GetRow, CM_SetRow
global CM_GetOutW, CM_GetOutH, CM_GetFlipH, CM_GetFlipV
global CM_LoadBitmapFile, CM_SetPictureBoxImage, CM_FindEntryByControl
global CM_CaptureThumb, CM_CollectCameras, CM_AddRowUI, CM_AddCameraUI
global CM_PopulateAll, CM_StartRefreshQueue, CM_StopRefreshQueue, CM_RefreshTimer_Tick
global CM_OnRefreshClick, CM_ExportAllThumbs, CM_BuildUI, CM_RenameCamera
global CM_OnPicClick, CM_OnPicDblClick, CM_OnPicMouseDown
global CM_OnNewRowOk, CM_OnAddRowClick, CM_OnOverlayChkChanged, CM_OnOverlayComboChanged
global CM_OnFlipHClick, CM_OnFlipVClick, CM_OnSearchChanged
global CM_OnMiRefreshClick, CM_OnMiRenameClick, CM_OnMiColorClick, CM_OnFormClosed
global CM_ln, CM_DrawGuides, CM_ToggleOverlay

-- helper: safe temp path
fn CM_TempThumbPath camName =
(
    local safe = (filterString camName " :\\/*?\"<>|")[1]
    (getDir #temp) + "\\CameraMax_" + safe + ".jpg"
)

-- userprop helpers
fn CM_GetProp cam key default_ =
(
    local v = getUserProp cam key
    if v == undefined then default_ else v
)
fn CM_SetProp cam key val = ( setUserProp cam key val )

fn CM_GetRow cam = CM_GetProp cam "CM_Row" "Cameras"
fn CM_SetRow cam v = CM_SetProp cam "CM_Row" v
fn CM_GetOutW cam = CM_GetProp cam "CM_OutW" (renderWidth as string)
fn CM_GetOutH cam = CM_GetProp cam "CM_OutH" (renderHeight as string)
fn CM_GetFlipH cam = CM_GetProp cam "CM_FlipH" "0"
fn CM_GetFlipV cam = CM_GetProp cam "CM_FlipV" "0"

-- safe image loader using MemoryStream clone (avoids file lock issues)
fn CM_LoadBitmapFile filepath =
(
    try
    (
        if not (doesFileExist filepath) then undefined
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

-- assign PictureBox image and dispose previous image safely
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

-- find entry by control (used by global handlers)
fn CM_FindEntryByControl ctrl =
(
    local found = undefined
    for ed in CameraMax_Entries where ed.picBox == ctrl do found = ed
    found
)

-- Capture viewport to JPG: hide camera target if present, set viewport to camera,
-- redraw, sleep briefly to allow GPU backends to update, call gw.getViewportDib.
-- Restore viewport/camera and target visibility afterwards. Returns path or undefined.
fn CM_CaptureThumb cam w:160 h:110 =
(
    local outFile = CM_TempThumbPath cam.name
    local ok = true
    local prevCam = undefined
    local prevType = undefined

    local tgt = undefined
    if isProperty cam "target" then
    (
        try ( tgt = cam.target ) catch ( tgt = undefined )
    )

    local tgtWasHidden = undefined
    if tgt != undefined then
    (
        try ( tgtWasHidden = isHidden tgt ) catch ( tgtWasHidden = undefined )
    )

    try
    (
        prevType = viewport.getType()
        prevCam  = (try (viewport.getCamera()) catch (undefined))

        if tgt != undefined and tgtWasHidden == false then
        (
            try ( hide tgt ) catch()
        )

        viewport.setType #view_camera
        viewport.setCamera cam
        redrawViews()
        completeRedraw()
        -- small pause helps on some GPU/viewport combinations
        sleep 60

        local dib = gw.getViewportDib()
        if dib != undefined then
        (
            local resized = bitmap w h color:(color 20 20 20)
            copy dib resized
            save resized filename:outFile quality:85
            close dib
            close resized
        )
        else ok = false
    ) catch ( ok = false )

    -- restore previous viewport/camera
    try
    (
        if prevCam != undefined then viewport.setCamera prevCam
        if prevType != undefined then viewport.setType prevType
        redrawViews()
        completeRedraw()
    ) catch()

    -- restore target visibility if we changed it
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
        -- apply flips if requested using .NET RotateFlip and re-save
        try
        (
            local flipH = ((CM_GetFlipH cam) as integer) == 1
            local flipV = ((CM_GetFlipV cam) as integer) == 1
            if (flipH or flipV) and (doesFileExist outFile) then
            (
                local bmp = dotNetObject "System.Drawing.Bitmap" outFile
                local rf = dotNetClass "System.Drawing.RotateFlipType"
                if flipH and flipV then bmp.RotateFlip rf.RotateNoneFlipXY
                else if flipH then bmp.RotateFlip rf.RotateNoneFlipX
                else bmp.RotateFlip rf.RotateNoneFlipY
                bmp.Save outFile
                bmp.Dispose()
            )
        ) catch()
        outFile
    )
    else undefined
)

-- Collect "true" cameras: exclude any object that is a .target of another camera
fn CM_CollectCameras =
(
    local cams = #()
    local candidates = for o in objects where isKindOf o camera collect o
    for o in candidates do
    (
        local isTargetOfOther = false
        for c in cameras where c != o do
        (
            try
            (
                if isProperty c "target" and c.target == o then
                (
                    isTargetOfOther = true
                    exit
                )
            ) catch()
        )
        if not isTargetOfOther then append cams o
    )
    cams
)

-- simple drawing helpers used by overlay guides
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
            local d = ((vpW*vpH) / (sqrt (vpW^2 + vpH^2)))
            CM_ln vpW 0 (vpW - d*vpH/vpW) vpH
            CM_ln 0 vpH (d*vpH/vpW) 0
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

-- Rename dialog OK handler
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

-- Add camera UI placeholder (no capture at build time)
fn CM_AddCameraUI cam =
(
    local rowName = CM_GetRow cam
    local rowData = undefined
    for r in CameraMax_Rows where r.rowName == rowName do rowData = r
    if rowData == undefined do rowData = CM_AddRowUI rowName (color 100 180 220)

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

    -- attach to global handlers (no closures)
    dotNet.addEventHandler pic "Click" CM_OnPicClick
    dotNet.addEventHandler pic "DoubleClick" CM_OnPicDblClick
    dotNet.addEventHandler pic "MouseDown" CM_OnPicMouseDown

    rowData.flowPanel.Controls.Add outer
    ed
)

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

-- Global thumbnail event handlers (use CM_FindEntryByControl)
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

-- Add row dialog handlers
fn CM_OnNewRowOk s e =
(
    if CM_NewRowTextBox.Text != "" then CM_AddRowUI CM_NewRowTextBox.Text (color (random 80 220) (random 80 220) (random 80 220))
    (s.FindForm()).Close()
)

fn CM_OnAddRowClick s e =
(
    local dlg = dotNetObject "System.Windows.Forms.Form"
    dlg.Text = "New Row"
    dlg.Size = dotNetObject "System.Drawing.Size" 280 110
    dlg.StartPosition = CM_FormStartPos.CenterScreen

    CM_NewRowTextBox = dotNetObject "System.Windows.Forms.TextBox"
    CM_NewRowTextBox.Location = dotNetObject "System.Drawing.Point" 10 15
    CM_NewRowTextBox.Size = dotNetObject "System.Drawing.Size" 240 24
    dlg.Controls.Add CM_NewRowTextBox

    local okBtn = dotNetObject "System.Windows.Forms.Button"
    okBtn.Text = "Add"
    okBtn.Location = dotNetObject "System.Drawing.Point" 90 50
    dotNet.addEventHandler okBtn "Click" CM_OnNewRowOk
    dlg.Controls.Add okBtn

    dlg.ShowDialog()
)

-- Refresh button toggles queue
fn CM_OnRefreshClick sender e =
(
    if CM_RefreshRunning == true then CM_StopRefreshQueue() else CM_StartRefreshQueue()
)

-- Start/stop refresh queue (timer-driven)
fn CM_StartRefreshQueue =
(
    try ( if CM_RefreshTimer != undefined then CM_StopRefreshQueue() ) catch()
    CM_RefreshQueueIndex = 1
    CM_RefreshRunning = true
    CM_RefreshTimer = dotNetObject "System.Windows.Forms.Timer"
    CM_RefreshTimer.Interval = 120 -- ms between captures
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

-- Timer tick: capture one thumbnail per tick with robust try/catch
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

        -- update progress
        CM_StatusLabel.Text = (CM_RefreshQueueIndex as string) + " / " + (CameraMax_Entries.count as string) + " thumbnails"

        CM_RefreshQueueIndex += 1
    ) catch
    (
        CM_StopRefreshQueue()
    )
)

-- Overlay handlers
fn CM_OnOverlayChkChanged sender e = ( CM_ToggleOverlay CM_OverlayChk.Checked )

fn CM_OnOverlayComboChanged sender e =
(
    case CM_OverlayCombo.SelectedIndex of
    (
        1: CameraMax_OverlayMode = "thirds"
        2: CameraMax_OverlayMode = "golden"
        3: CameraMax_OverlayMode = "triangle"
        default: CameraMax_OverlayMode = "thirds"
    )
    CM_OverlayChk.Checked = (CM_OverlayCombo.SelectedIndex != 0)
)

-- Flip handlers (toggle userprops on selected camera)
fn CM_OnFlipHClick sender e =
(
    if selection.count == 1 and isKindOf selection[1] camera then
    (
        local cam = selection[1]
        local cur = (CM_GetFlipH cam) as integer
        CM_SetProp cam "CM_FlipH" ((1 - cur) as string)
    )
)

fn CM_OnFlipVClick sender e =
(
    if selection.count == 1 and isKindOf selection[1] camera then
    (
        local cam = selection[1]
        local cur = (CM_GetFlipV cam) as integer
        CM_SetProp cam "CM_FlipV" ((1 - cur) as string)
    )
)

-- search box handler
fn CM_OnSearchChanged sender e =
(
    local q = toLower CM_SearchBox.Text
    for ed in CameraMax_Entries do
    (
        local visible = (q == "") or (findString (toLower ed.cam.name) q != undefined)
        ed.picBox.Parent.Visible = visible
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

-- Export all thumbnails to chosen folder
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

-- Build the UI (placeholders only)
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

    local outBtn = dotNetObject "System.Windows.Forms.Button"
    outBtn.Text = "Output"
    outBtn.Location = dotNetObject "System.Drawing.Point" 10 610
    outBtn.Size = dotNetObject "System.Drawing.Size" 70 26
    CM_Form.Controls.Add outBtn

    local sceneBtn = dotNetObject "System.Windows.Forms.Button"
    sceneBtn.Text = "Scene"
    sceneBtn.Location = dotNetObject "System.Drawing.Point" 85 610
    sceneBtn.Size = dotNetObject "System.Drawing.Size" 60 26
    CM_Form.Controls.Add sceneBtn

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

    -- Add event handlers (global functions)
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

-- Build the UI now
CM_BuildUI()

-- Macro wrapper
macroScript CameraMax_Open
category:"CameraMax"
buttonText:"CameraMax"
tooltip:"Open CameraMax camera manager"
(
    on execute do CM_BuildUI()
)