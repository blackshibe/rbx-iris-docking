--!optimize 2
-- Docking: a split-tree dock layout for Iris windows.
--
-- A dock tree is built from "leaf" nodes (each holding one or more windows shown as
-- tabs) and "split" nodes (two children divided horizontally or vertically by a
-- draggable splitter). Each cycle Iris.DockSpace() recomputes every node's rect and
-- drives the docked windows' position/size/visibility through their public state, so
-- the layer stays decoupled from the Window widget internals (which only learn that a
-- window is docked through `widget.dockId`).

local Types = require(script.Parent.Parent.Types)

return function(Iris: Types.Internal, widgets: Types.WidgetUtility)
    print("[DOCK] Docking.luau loaded — build v26 (serialize export fix)")
    local TAB_HEIGHT = 24
    local GUTTER = 2 -- visible gap between panels
    local GRAB = 7 -- splitter mouse hit-area (wider than the visible gutter)
    -- dock surface sits BELOW windows (DisplayOrderOffset = 127), so floating windows draw
    -- over it and receive clicks. The drag catcher is the exception: it lives in PopupScreenGui
    -- (above every window) so it can capture the release wherever the cursor ends up.
    -- ZIndexBehavior.Sibling orders WHOLE subtrees by their root's ZIndex, so the stack is set
    -- entirely by the sibling roots under PseudoWindowScreenGui: docked windows must sit BELOW
    -- the dock container (so its splitters/tab bars are grabbable over them), while floating
    -- windows (≥ DisplayOrderOffset, raised on focus) sit ABOVE the container.
    local DOCKED_WINDOW_ZINDEX = 5
    local DOCK_ZINDEX = 10
    local CATCHER_ZINDEX = 2_000_000

    local dock = {
        nodes = {} :: { [string]: any },
        windowToLeaf = {} :: { [string]: string },
        rootId = nil :: string?,
        nextId = 0,
        container = nil :: Frame?,
        tabBars = {} :: { [string]: Frame }, -- leafId -> tab bar frame
        tabButtons = {} :: { [string]: TextButton }, -- windowId -> tab button
        splitters = {} :: { [string]: TextButton }, -- splitId -> splitter handle
        activeSplitter = nil :: string?,
        dragCatcher = nil :: TextButton?, -- full-screen capture button shown while dragging
        dragWindowId = nil :: string?, -- id of the floating window currently being dragged (set by Window.luau)
        hoverDrop = nil :: { leafId: string?, side: string }?, -- drop target under the cursor this frame
        overlay = nil :: any, -- lazily-built drop-zone overlay instances
    }
    Iris._dock = dock

    local function nextId(): string
        dock.nextId += 1
        return "docknode_" .. dock.nextId
    end

    local function makeLeaf(): string
        local id: string = nextId()
        dock.nodes[id] = { id = id, kind = "leaf", windows = {}, active = nil, parent = nil }
        return id
    end

    -- descend a subtree to its first leaf node id (nil if the subtree is empty/broken)
    local function firstLeafUnder(nodeId: string?): string?
        if nodeId == nil then
            return nil
        end
        local node = dock.nodes[nodeId]
        if node == nil then
            return nil
        end
        if node.kind == "leaf" then
            return nodeId
        end
        return firstLeafUnder(node.childA) or firstLeafUnder(node.childB)
    end

    -- removes a window from whatever leaf holds it, collapsing empty leaves and their
    -- parent split so the sibling takes over the freed space.
    local function detachWindow(windowId: string)
        local leafId: string? = dock.windowToLeaf[windowId]
        if leafId == nil then
            return
        end
        dock.windowToLeaf[windowId] = nil
        local leaf = dock.nodes[leafId]
        if leaf == nil then
            return
        end

        local kept: { string } = {}
        for _, id in leaf.windows do
            if id ~= windowId then
                table.insert(kept, id)
            end
        end
        leaf.windows = kept
        if leaf.active == windowId then
            leaf.active = kept[1]
        end

        if #kept > 0 then
            return
        end

        -- empty leaf: remove it and promote its sibling into the parent's slot
        local parentId: string? = leaf.parent
        dock.nodes[leafId] = nil
        if parentId == nil then
            dock.rootId = nil
            return
        end

        local parent = dock.nodes[parentId]
        local siblingId: string = if parent.childA == leafId then parent.childB else parent.childA
        local sibling = dock.nodes[siblingId]
        local grandId: string? = parent.parent
        sibling.parent = grandId
        dock.nodes[parentId] = nil
        if grandId == nil then
            dock.rootId = siblingId
        else
            local grand = dock.nodes[grandId]
            if grand.childA == parentId then
                grand.childA = siblingId
            else
                grand.childB = siblingId
            end
        end
    end

    -- public: docks a window. side is "left"|"right"|"top"|"bottom"|"center". When a
    -- targetWindowId is given the operation is relative to that window's leaf, otherwise
    -- to the whole dockspace root.
    function Iris.DockWindow(windowId: string, side: string?, targetWindowId: string?)
        detachWindow(windowId)
        side = side or "center"
        print("[DOCK] DockWindow", windowId, "side=", side, "target=", targetWindowId, "rootId=", dock.rootId)

        if dock.rootId == nil then
            local leafId: string = makeLeaf()
            dock.rootId = leafId
            local leaf = dock.nodes[leafId]
            table.insert(leaf.windows, windowId)
            leaf.active = windowId
            dock.windowToLeaf[windowId] = leafId
            print("[DOCK]   -> first leaf", leafId, "(now root)")
            return
        end

        local targetLeafId: string = if targetWindowId and dock.windowToLeaf[targetWindowId] then dock.windowToLeaf[targetWindowId] else dock.rootId
        local targetLeaf = dock.nodes[targetLeafId]

        if side == "center" or targetLeaf == nil or targetLeaf.kind ~= "leaf" then
            -- tab into the target leaf; if the target isn't a usable leaf, find any leaf
            -- under the root, and only as a last resort make the window its own root leaf.
            local leafId: string? = if targetLeaf and targetLeaf.kind == "leaf" then targetLeafId else firstLeafUnder(dock.rootId)
            if leafId == nil then
                print("[SE] dock fallback: no leaf found", "win=", windowId, "side=", side, "target=", targetWindowId, "rootId=", dock.rootId)
                leafId = makeLeaf()
                dock.rootId = leafId
            end
            local leaf = dock.nodes[leafId]
            table.insert(leaf.windows, windowId)
            leaf.active = windowId
            dock.windowToLeaf[windowId] = leafId :: string
            print("[DOCK]   -> tabbed into leaf", leafId, "tabs=", #leaf.windows)
            return
        end

        -- split the target leaf, inserting a new leaf for the window
        local newLeafId: string = makeLeaf()
        local newLeaf = dock.nodes[newLeafId]
        table.insert(newLeaf.windows, windowId)
        newLeaf.active = windowId
        dock.windowToLeaf[windowId] = newLeafId

        local splitId: string = nextId()
        local horizontal: boolean = side == "left" or side == "right"
        local newFirst: boolean = side == "left" or side == "top"
        dock.nodes[splitId] = {
            id = splitId,
            kind = "split",
            orientation = if horizontal then "h" else "v",
            childA = if newFirst then newLeafId else targetLeafId,
            childB = if newFirst then targetLeafId else newLeafId,
            ratio = 0.4,
            parent = targetLeaf.parent,
        }

        local parentId: string? = targetLeaf.parent
        targetLeaf.parent = splitId
        newLeaf.parent = splitId

        if parentId == nil then
            dock.rootId = splitId
        else
            local parent = dock.nodes[parentId]
            if parent.childA == targetLeafId then
                parent.childA = splitId
            else
                parent.childB = splitId
            end
        end
        print("[DOCK]   -> split", splitId, dock.nodes[splitId].orientation, "newLeaf=", newLeafId, "target=", targetLeafId)
    end

    function Iris.UndockWindow(windowId: string)
        print("[DOCK] UndockWindow", windowId, "wasDocked=", dock.windowToLeaf[windowId] ~= nil)
        detachWindow(windowId)
        local widget: Types.Widget? = Iris._windowWidgets[windowId]
        if widget then
            widget.dockId = nil
            -- restore the floating chrome the dock had overridden: resize grip back, collapse
            -- arrow back to the down (minimize) glyph. (Window.Update only refreshes on argument
            -- change, so the dock drives these directly.)
            local inst = widget.Instance
            local windowButton = inst and inst:FindFirstChild("WindowButton")
            if windowButton then
                local grip = windowButton:FindFirstChild("ResizeGrip")
                if grip then
                    grip.Visible = widget.arguments.NoResize ~= true
                end
                local content = windowButton:FindFirstChild("Content")
                local titleBar = content and content:FindFirstChild("TitleBar")
                local collapseButton = titleBar and titleBar:FindFirstChild("CollapseButton")
                local arrow = collapseButton and collapseButton:FindFirstChild("Arrow")
                if arrow then
                    (arrow :: ImageLabel).Image = widgets.ICONS.DOWN_POINTING_TRIANGLE
                end
            end
            -- restore as a visible floating window: the dock may have hidden it (inactive tab)
            -- and left it at the full leaf rect, so give it a modest cascaded size/position and
            -- focus it so it sits above the still-docked windows instead of behind them.
            widget.state.isOpened:set(true)
            widget.state.isUncollapsed:set(true)
            dock.undockCascade = (dock.undockCascade or 0) + 1
            local step: number = ((dock.undockCascade - 1) % 8) * 28
            widget.state.position:set(Vector2.new(80 + step, 80 + step))
            widget.state.size:set(Vector2.new(420, 320))
            -- the dock pinned this window's ZIndex to the docked band; SetFocusedWindow raises it
            -- back to the floating band, but it early-outs if the window is already focused, so
            -- clear focus first to guarantee the re-raise above the dock surface.
            Iris.SetFocusedWindow(nil)
            Iris.SetFocusedWindow(widget)
        end
    end

    function Iris.IsWindowDocked(windowId: string): boolean
        return dock.windowToLeaf[windowId] ~= nil
    end

    -- serialization ----------------------------------------------------------------
    -- Produce a plain (JSON-safe) snapshot of the workspace: the split tree, each leaf's tab
    -- membership/active tab and splitter ratios, plus geometry of floating windows. parent
    -- pointers and windowToLeaf are derived on load, so they are not stored.
    function Iris.SerializeDock(): { [string]: any }
        local nodes: { [string]: any } = {}
        for id, node in dock.nodes do
            if node.kind == "leaf" then
                local windows: { string } = {}
                for i, w in node.windows do
                    windows[i] = w
                end
                nodes[id] = { kind = "leaf", windows = windows, active = node.active }
            elseif node.kind == "split" then
                nodes[id] = {
                    kind = "split",
                    orientation = node.orientation,
                    childA = node.childA,
                    childB = node.childB,
                    ratio = node.ratio,
                }
            end
        end

        local floating: { [string]: any } = {}
        for windowId, widget in Iris._windowWidgets do
            if type(widget.dockId) ~= "string" and widget.state then
                local pos: Vector2 = widget.state.position.value
                local size: Vector2 = widget.state.size.value
                floating[windowId] = {
                    px = pos.X,
                    py = pos.Y,
                    sx = size.X,
                    sy = size.Y,
                    isOpened = widget.state.isOpened.value,
                    isUncollapsed = widget.state.isUncollapsed.value,
                }
            end
        end

        return { version = 1, rootId = dock.rootId, nextId = dock.nextId, nodes = nodes, floating = floating }
    end

    -- Rebuild the workspace from a SerializeDock() snapshot. Safe to call before the windows
    -- themselves exist: the tree binds each window as it next appears in DockSpace. Returns
    -- false if the data is not a usable snapshot.
    function Iris.DeserializeDock(data: { [string]: any }?): boolean
        if type(data) ~= "table" or type(data.nodes) ~= "table" then
            return false
        end

        -- any window docked under the OLD tree that the new tree doesn't mention goes floating
        local newWindowToLeaf: { [string]: string } = {}
        for id, n in data.nodes do
            if n.kind == "leaf" and type(n.windows) == "table" then
                for _, w in n.windows do
                    newWindowToLeaf[w] = id
                end
            end
        end
        for windowId, widget in Iris._windowWidgets do
            if type(widget.dockId) == "string" and newWindowToLeaf[windowId] == nil then
                widget.dockId = nil
            end
        end

        dock.nodes = {}
        dock.windowToLeaf = {}
        dock.rootId = data.rootId
        local maxId: number = 0
        for id, n in data.nodes do
            if n.kind == "leaf" then
                local windows: { string } = {}
                for i, w in n.windows do
                    windows[i] = w
                end
                dock.nodes[id] = { id = id, kind = "leaf", windows = windows, active = n.active, parent = nil }
                for _, w in windows do
                    dock.windowToLeaf[w] = id
                end
            elseif n.kind == "split" then
                dock.nodes[id] =
                    { id = id, kind = "split", orientation = n.orientation, childA = n.childA, childB = n.childB, ratio = n.ratio or 0.5, parent = nil }
            end
            local num: number? = tonumber(string.match(id, "docknode_(%d+)"))
            if num and num > maxId then
                maxId = num
            end
        end

        -- derive parent links from the split children
        for id, node in dock.nodes do
            if node.kind == "split" then
                local a = dock.nodes[node.childA]
                local b = dock.nodes[node.childB]
                if a then
                    a.parent = id
                end
                if b then
                    b.parent = id
                end
            end
        end

        -- keep id generation ahead of anything we just loaded so new docks don't collide
        dock.nextId = math.max(tonumber(data.nextId) or 0, maxId)

        for windowId, leafId in dock.windowToLeaf do
            local widget = Iris._windowWidgets[windowId]
            if widget then
                widget.dockId = leafId
            end
        end

        if type(data.floating) == "table" then
            for windowId, f in data.floating do
                local widget = Iris._windowWidgets[windowId]
                if widget and type(widget.dockId) ~= "string" and widget.state then
                    widget.state.position:set(Vector2.new(f.px or 0, f.py or 0))
                    widget.state.size:set(Vector2.new(f.sx or 400, f.sy or 300))
                    if f.isOpened ~= nil then
                        widget.state.isOpened:set(f.isOpened)
                    end
                    if f.isUncollapsed ~= nil then
                        widget.state.isUncollapsed:set(f.isUncollapsed)
                    end
                end
            end
        end

        return true
    end

    -- rect computation -----------------------------------------------------------

    local function computeRects(nodeId: string, pos: Vector2, size: Vector2)
        local node = dock.nodes[nodeId]
        if node == nil then
            return
        end
        node.rect = { pos = pos, size = size }
        if node.kind ~= "split" then
            return
        end

        if node.orientation == "h" then
            local aw: number = math.floor((size.X - GUTTER) * node.ratio)
            computeRects(node.childA, pos, Vector2.new(aw, size.Y))
            computeRects(node.childB, pos + Vector2.new(aw + GUTTER, 0), Vector2.new(size.X - aw - GUTTER, size.Y))
        else
            local ah: number = math.floor((size.Y - GUTTER) * node.ratio)
            computeRects(node.childA, pos, Vector2.new(size.X, ah))
            computeRects(node.childB, pos + Vector2.new(0, ah + GUTTER), Vector2.new(size.X, size.Y - ah - GUTTER))
        end
    end

    -- instance helpers ------------------------------------------------------------

    local function ensureContainer(): Frame?
        if Iris._rootInstance == nil then
            return nil
        end
        if dock.container and dock.container.Parent then
            return dock.container
        end
        -- parent into the window layer (not PopupScreenGui) so windows can draw over the dock
        local windowLayer = Iris._rootInstance:FindFirstChild("PseudoWindowScreenGui")
        if windowLayer == nil then
            return nil
        end
        local container = Instance.new("Frame")
        container.Name = "IrisDockSpace"
        container.BackgroundTransparency = 1
        container.BorderSizePixel = 0
        container.Size = UDim2.fromScale(1, 1)
        container.ZIndex = DOCK_ZINDEX
        container.Parent = windowLayer
        dock.container = container
        return container
    end

    local function setStateIfChanged(state: Types.State, value: any)
        if state and state.value ~= value then
            state:set(value)
        end
    end

    -- a window's own chrome (Update) is only refreshed on argument change, never when it gets
    -- docked, so we drive the docked appearance here every frame: no resize grip, and the
    -- collapse button repurposed as an undock control (right-pointing arrow; the click handler
    -- in Window.luau undocks when the window is docked).
    local function applyDockedChrome(inst: GuiObject)
        local windowButton = inst:FindFirstChild("WindowButton")
        if windowButton == nil then
            return
        end
        local grip = windowButton:FindFirstChild("ResizeGrip")
        if grip then
            grip.Visible = false
        end
        local content = windowButton:FindFirstChild("Content")
        local titleBar = content and content:FindFirstChild("TitleBar")
        local collapseButton = titleBar and titleBar:FindFirstChild("CollapseButton")
        local arrow = collapseButton and collapseButton:FindFirstChild("Arrow")
        if arrow and (arrow :: ImageLabel).Image ~= widgets.ICONS.RIGHT_POINTING_TRIANGLE then
            (arrow :: ImageLabel).Image = widgets.ICONS.RIGHT_POINTING_TRIANGLE
        end
    end

    -- UserInputService events do NOT fire over a plugin widget (verified: splitter DOWN
    -- fires from the GuiButton, but the registered UIS InputChanged/InputEnded never run).
    -- So we drive the drag per-frame from DockSpace via getMouseLocation() (which works in a
    -- plugin through GetRelativeMousePosition) and detect release from the PluginGui's own
    -- input events, which — unlike UIS — do fire over the widget.
    local function releaseSplitter()
        local held = dock.activeSplitter
        dock.activeSplitter = nil
        if dock.dragCatcher then
            dock.dragCatcher.Visible = false
        end
        if held == nil then
            return
        end
        local splitter = dock.splitters[held]
        local line = splitter and splitter:FindFirstChild("Line") :: Frame?
        if line then
            line.BackgroundColor3 = Iris._config.BorderColor
            line.BackgroundTransparency = Iris._config.BorderTransparency
        end
    end

    -- a full-screen transparent button shown only while dragging a splitter. The cursor is
    -- always over it, so its InputEnded reliably catches the release wherever the mouse is
    -- (the splitter's own InputEnded would miss it once the cursor leaves the thin handle,
    -- and UserInputService never fires over a plugin widget at all).
    local function ensureDragCatcher(): TextButton?
        if dock.dragCatcher and dock.dragCatcher.Parent then
            return dock.dragCatcher
        end
        -- the catcher must sit ABOVE the windows so it captures the release wherever the
        -- cursor lands; PopupScreenGui renders entirely above the window layer (Sibling
        -- ZIndexBehavior), unlike the dock container which lives in the window layer.
        local popup = Iris._rootInstance and Iris._rootInstance:FindFirstChild("PopupScreenGui")
        if popup == nil then
            return nil
        end
        local catcher = Instance.new("TextButton")
        catcher.Name = "DockDragCatcher"
        catcher.Text = ""
        catcher.AutoButtonColor = false
        catcher.BackgroundTransparency = 1
        catcher.BorderSizePixel = 0
        catcher.Size = UDim2.fromScale(1, 1)
        catcher.Visible = false
        catcher.ZIndex = CATCHER_ZINDEX
        catcher.Parent = popup
        local function onEnd(input: InputObject)
            print("[DOCK] catcher InputEnded", input.UserInputType, "active=", dock.activeSplitter)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                print("[DOCK] release splitter", dock.activeSplitter)
                releaseSplitter()
            end
        end
        catcher.InputEnded:Connect(onEnd)
        catcher.MouseButton1Up:Connect(function()
            print("[DOCK] catcher MouseButton1Up active=", dock.activeSplitter)
            releaseSplitter()
        end)
        dock.dragCatcher = catcher
        return catcher
    end

    -- per-frame ratio update for the splitter currently being dragged
    local function updateActiveSplitter()
        if dock.activeSplitter == nil then
            return
        end
        local node = dock.nodes[dock.activeSplitter]
        if node == nil or node.kind ~= "split" or node.rect == nil then
            return
        end
        local mouse: Vector2 = widgets.getMouseLocation()
        local rect = node.rect
        if node.orientation == "h" then
            node.ratio = math.clamp((mouse.X - rect.pos.X) / math.max(rect.size.X, 1), 0.05, 0.95)
        else
            node.ratio = math.clamp((mouse.Y - rect.pos.Y) / math.max(rect.size.Y, 1), 0.05, 0.95)
        end
        print("[DOCK] drag(frame)", dock.activeSplitter, "mouse=", mouse, "ratio=", string.format("%.3f", node.ratio))
    end

    -- imgui-style drop-zone overlay --------------------------------------------------
    -- While a floating window is dragged over the dockspace we show a 5-way target (centre +
    -- four directions) for the leaf under the cursor and a translucent preview of where the
    -- window would land. Detection is pure math against the cached leaf rects in the same
    -- coordinate space getMouseLocation() reports (verified by the splitter drag), so it does
    -- not rely on GuiObject input (unreliable over a plugin widget). The overlay lives in
    -- PopupScreenGui so it draws above the dragged window (which sits in the window layer).
    local ZONE = 34 -- drop-zone marker size (px)
    local ZONE_GAP = 8 -- gap between the centre marker and the directional ones
    local ZONE_COLOR = Color3.fromRGB(38, 143, 255)

    local function rectContains(p: Vector2, pos: Vector2, size: Vector2): boolean
        return p.X >= pos.X and p.X <= pos.X + size.X and p.Y >= pos.Y and p.Y <= pos.Y + size.Y
    end

    local function newZoneMarker(parent: Instance, z: number): Frame
        local m = Instance.new("Frame")
        m.BorderSizePixel = 0
        m.BackgroundColor3 = ZONE_COLOR
        m.BackgroundTransparency = 0.5
        m.Size = UDim2.fromOffset(ZONE, ZONE)
        m.ZIndex = z
        m.Visible = false
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(255, 255, 255)
        stroke.Transparency = 0.3
        stroke.Thickness = 1
        stroke.Parent = m
        widgets.UICorner(m, 4)
        m.Parent = parent
        return m
    end

    local function ensureOverlay()
        if dock.overlay and dock.overlay.root.Parent then
            return dock.overlay
        end
        local popup = Iris._rootInstance and Iris._rootInstance:FindFirstChild("PopupScreenGui")
        if popup == nil then
            return nil
        end
        local root = Instance.new("Frame")
        root.Name = "IrisDockOverlay"
        root.BackgroundTransparency = 1
        root.BorderSizePixel = 0
        root.Size = UDim2.fromScale(1, 1)
        root.ZIndex = 1_500_000
        root.Visible = false
        root.Parent = popup

        local preview = Instance.new("Frame")
        preview.Name = "Preview"
        preview.BorderSizePixel = 0
        preview.BackgroundColor3 = ZONE_COLOR
        preview.BackgroundTransparency = 0.7
        preview.ZIndex = 1_500_000
        preview.Visible = false
        preview.Parent = root

        local markers = {
            center = newZoneMarker(root, 1_500_002),
            left = newZoneMarker(root, 1_500_002),
            right = newZoneMarker(root, 1_500_002),
            top = newZoneMarker(root, 1_500_002),
            bottom = newZoneMarker(root, 1_500_002),
        }
        dock.overlay = { root = root, preview = preview, markers = markers }
        return dock.overlay
    end

    -- the screen region a window would occupy if dropped on `side` of `rect`
    local function previewRegion(rect: { pos: Vector2, size: Vector2 }, side: string): (Vector2, Vector2)
        local p, s = rect.pos, rect.size
        if side == "left" then
            return p, Vector2.new(s.X / 2, s.Y)
        elseif side == "right" then
            return p + Vector2.new(s.X / 2, 0), Vector2.new(s.X / 2, s.Y)
        elseif side == "top" then
            return p, Vector2.new(s.X, s.Y / 2)
        elseif side == "bottom" then
            return p + Vector2.new(0, s.Y / 2), Vector2.new(s.X, s.Y / 2)
        end
        return p, s -- center: whole leaf
    end

    local function updateDockOverlay(container: Frame)
        local overlay = ensureOverlay()
        if overlay == nil then
            return
        end
        if dock.dragWindowId == nil then
            overlay.root.Visible = false
            dock.hoverDrop = nil
            return
        end
        overlay.root.Visible = true
        local mouse: Vector2 = widgets.getMouseLocation()

        -- find the leaf rect under the cursor (or the whole container when nothing is docked yet)
        local targetLeafId: string? = nil
        local leafRect: { pos: Vector2, size: Vector2 }? = nil
        if dock.rootId == nil then
            leafRect = { pos = Vector2.zero, size = container.AbsoluteSize }
        else
            for id, node in dock.nodes do
                if node.kind == "leaf" and node.rect and rectContains(mouse, node.rect.pos, node.rect.size) then
                    targetLeafId = id
                    leafRect = node.rect
                    break
                end
            end
        end

        local emptySpace: boolean = dock.rootId == nil
        if leafRect == nil then
            for _, m in overlay.markers do
                m.Visible = false
            end
            overlay.preview.Visible = false
            dock.hoverDrop = nil
            return
        end

        -- the cross of markers is purely visual feedback; the drop side is chosen by WHICH
        -- region of the leaf the cursor sits in (outer EDGE fraction on a side → that direction,
        -- middle → tab). A tiny centre marker was nearly impossible to aim for, so every drop
        -- collapsed to a centre-tab — windows piled into one leaf and hid each other.
        local center: Vector2 = leafRect.pos + leafRect.size / 2
        local half: number = ZONE / 2
        local step: number = ZONE + ZONE_GAP
        local spots: { [string]: Vector2 } = {
            center = center,
            left = center - Vector2.new(step, 0),
            right = center + Vector2.new(step, 0),
            top = center - Vector2.new(0, step),
            bottom = center + Vector2.new(0, step),
        }

        local side: string = "center"
        if not emptySpace then
            local EDGE: number = 0.30 -- outer 30% on a side docks to that side; middle tabs
            local fx: number = (mouse.X - leafRect.pos.X) / math.max(leafRect.size.X, 1)
            local fy: number = (mouse.Y - leafRect.pos.Y) / math.max(leafRect.size.Y, 1)
            local dl, dr, dt, db = fx, 1 - fx, fy, 1 - fy
            local nearest: number = math.min(dl, dr, dt, db)
            if nearest >= EDGE then
                side = "center"
            elseif nearest == dl then
                side = "left"
            elseif nearest == dr then
                side = "right"
            elseif nearest == dt then
                side = "top"
            else
                side = "bottom"
            end
        end

        -- draw/highlight the marker cross (directional markers hidden when nothing is docked yet)
        for name, spot in spots do
            local visible: boolean = not (emptySpace and name ~= "center")
            local m = overlay.markers[name]
            m.Visible = visible
            m.Position = UDim2.fromOffset(spot.X - half, spot.Y - half)
            m.BackgroundTransparency = if name == side then 0.15 else 0.5
        end

        -- over a leaf → always a valid drop target; release outside any leaf leaves it floating
        local rpos, rsize = previewRegion(leafRect, side)
        overlay.preview.Visible = true
        overlay.preview.Position = UDim2.fromOffset(rpos.X, rpos.Y)
        overlay.preview.Size = UDim2.fromOffset(rsize.X, rsize.Y)
        dock.hoverDrop = { leafId = targetLeafId, side = side }
    end

    -- called by Window.luau when a floating-window drag is released: docks into the hovered
    -- zone if there is one, otherwise leaves the window floating. Always clears drag/overlay.
    function Iris.DockDrop(windowId: string): boolean
        local drop = dock.hoverDrop
        dock.dragWindowId = nil
        dock.hoverDrop = nil
        if dock.overlay then
            dock.overlay.root.Visible = false
        end
        if drop == nil then
            return false
        end
        if drop.leafId == nil then
            Iris.DockWindow(windowId) -- empty dockspace: window becomes the root leaf
        else
            local leaf = dock.nodes[drop.leafId]
            local anchor: string? = leaf and leaf.active
            Iris.DockWindow(windowId, drop.side, anchor)
        end
        return true
    end

    -- a splitter is a wide transparent hit-area (GRAB) with a thin visible line (GUTTER)
    -- centred inside it, so the divider reads as a hairline but is still easy to grab.
    local function getSplitter(splitId: string, container: Frame): TextButton
        local splitter = dock.splitters[splitId]
        if splitter == nil then
            splitter = Instance.new("TextButton")
            splitter.Name = "Splitter"
            splitter.Text = ""
            splitter.AutoButtonColor = false
            splitter.BorderSizePixel = 0
            splitter.BackgroundTransparency = 1
            splitter.ZIndex = DOCK_ZINDEX + 3
            splitter.Parent = container

            local line = Instance.new("Frame")
            line.Name = "Line"
            line.AnchorPoint = Vector2.new(0.5, 0.5)
            line.Position = UDim2.fromScale(0.5, 0.5)
            line.BorderSizePixel = 0
            line.BackgroundColor3 = Iris._config.BorderColor
            line.BackgroundTransparency = Iris._config.BorderTransparency
            line.ZIndex = DOCK_ZINDEX + 3
            line.Parent = splitter

            splitter.MouseButton1Down:Connect(function()
                print("[DOCK] splitter DOWN", splitId)
                dock.activeSplitter = splitId
                if dock.dragCatcher then
                    dock.dragCatcher.Visible = true
                end
                line.BackgroundColor3 = Iris._config.BorderActiveColor
                line.BackgroundTransparency = 0
            end)
            splitter.MouseEnter:Connect(function()
                print("[DOCK] splitter ENTER", splitId)
                if dock.activeSplitter == nil then
                    line.BackgroundColor3 = Iris._config.BorderActiveColor
                    line.BackgroundTransparency = 0.3
                end
            end)
            splitter.MouseLeave:Connect(function()
                if dock.activeSplitter ~= splitId then
                    line.BackgroundColor3 = Iris._config.BorderColor
                    line.BackgroundTransparency = Iris._config.BorderTransparency
                end
            end)
            dock.splitters[splitId] = splitter
        end
        return splitter
    end

    local function getTabBar(leafId: string, container: Frame): Frame
        local bar = dock.tabBars[leafId]
        if bar == nil then
            bar = Instance.new("Frame")
            bar.Name = "TabBar"
            bar.BorderSizePixel = 0
            bar.BackgroundColor3 = Iris._config.TitleBgColor
            bar.BackgroundTransparency = Iris._config.TitleBgTransparency
            bar.ZIndex = DOCK_ZINDEX + 1
            local layout = Instance.new("UIListLayout")
            layout.FillDirection = Enum.FillDirection.Horizontal
            layout.SortOrder = Enum.SortOrder.LayoutOrder
            layout.Padding = UDim.new(0, 2)
            layout.Parent = bar
            bar.Parent = container
            dock.tabBars[leafId] = bar
        end
        return bar
    end

    local function buildTabButton(windowId: string): TextButton
        local button = Instance.new("TextButton")
        button.Name = "Tab_" .. windowId
        button.AutomaticSize = Enum.AutomaticSize.X
        button.Size = UDim2.fromOffset(0, TAB_HEIGHT - 4)
        button.BorderSizePixel = 0
        button.AutoButtonColor = false
        button.ZIndex = DOCK_ZINDEX + 2
        widgets.applyTextStyle(button :: any)

        -- tabs are purely for selecting the active window in a leaf; undocking is done from the
        -- window's title-bar arrow (a per-tab ✕ sat against the title and caused mis-undocks).
        local padding = Instance.new("UIPadding")
        padding.PaddingLeft = UDim.new(0, 8)
        padding.PaddingRight = UDim.new(0, 8)
        padding.PaddingTop = UDim.new(0, 2)
        padding.PaddingBottom = UDim.new(0, 2)
        padding.Parent = button

        button.MouseButton1Click:Connect(function()
            local leafId: string? = dock.windowToLeaf[windowId]
            if leafId and dock.nodes[leafId] then
                dock.nodes[leafId].active = windowId
            end
        end)
        -- right-click stays as a quick undock shortcut (cannot misfire on a left-click select)
        button.MouseButton2Click:Connect(function()
            Iris.UndockWindow(windowId)
        end)
        return button
    end

    local function getTabButton(windowId: string, bar: Frame): TextButton
        local button = dock.tabButtons[windowId]
        if button == nil then
            button = buildTabButton(windowId)
            dock.tabButtons[windowId] = button
        end
        -- a cached button may have been destroyed as a cascade of its old tab bar being
        -- reaped; reparenting a destroyed instance errors, so rebuild it if that happens.
        local ok: boolean = pcall(function()
            button.Parent = bar
        end)
        if not ok then
            button = buildTabButton(windowId)
            dock.tabButtons[windowId] = button
            button.Parent = bar
        end
        return button
    end

    -- the per-cycle dockspace pass ------------------------------------------------

    -- offset/size are optional; when omitted the dockspace fills the whole container.
    -- Pass them to leave room for a menu bar or status strip at the top.
    function Iris.DockSpace(offset: Vector2?, size: Vector2?)
        updateActiveSplitter()
        local container: Frame? = ensureContainer()

        -- throttled heartbeat: only print when the container availability or the tree
        -- shape changes, so we see structural events without per-frame spam.
        local leaves, splits = 0, 0
        for _, node in dock.nodes do
            if node.kind == "leaf" then
                leaves += 1
            elseif node.kind == "split" then
                splits += 1
            end
        end
        local sig: string = string.format(
            "c=%s root=%s leaves=%d splits=%d",
            tostring(container ~= nil),
            tostring(dock.rootId),
            leaves,
            splits
        )
        local changed: boolean = sig ~= dock._lastSig
        if changed then
            dock._lastSig = sig
            dock._dumpFrames = 4 -- dump settled geometry/zindex for a few frames after a change
            print(
                "[DOCK] DockSpace state:",
                sig,
                "rootInstance=",
                Iris._rootInstance ~= nil,
                "containerAbsSize=",
                if container then container.AbsoluteSize else nil
            )
        end

        -- drop-zone overlay runs even with an empty dockspace, so the first window can be dropped
        if container ~= nil then
            updateDockOverlay(container)
        end

        if container == nil or dock.rootId == nil then
            return
        end
        ensureDragCatcher()

        local origin: Vector2 = offset or Vector2.zero
        local area: Vector2 = size or (container.AbsoluteSize - origin)
        computeRects(dock.rootId, origin, area)

        if changed then
            for nodeId, node in dock.nodes do
                if node.kind == "leaf" and node.rect then
                    local n: number = #node.windows
                    local active: string = tostring(node.active)
                    local widget = if node.active then Iris._windowWidgets[node.active] else nil
                    print(
                        "[DOCK]   leaf",
                        nodeId,
                        "pos=",
                        node.rect.pos,
                        "size=",
                        node.rect.size,
                        "windows=",
                        n,
                        "active=",
                        active,
                        "widgetExists=",
                        widget ~= nil
                    )
                end
            end
        end

        -- track which UI instances are still alive this cycle
        local liveLeaves: { [string]: boolean } = {}
        local liveTabs: { [string]: boolean } = {}
        local liveSplitters: { [string]: boolean } = {}

        for nodeId, node in dock.nodes do
            if node.kind == "split" and node.rect then
                local splitter = getSplitter(nodeId, container)
                liveSplitters[nodeId] = true
                local line = splitter:FindFirstChild("Line") :: Frame?
                if node.orientation == "h" then
                    local aw: number = math.floor((node.rect.size.X - GUTTER) * node.ratio)
                    local gapCenter: number = node.rect.pos.X + aw + GUTTER / 2
                    splitter.Position = UDim2.fromOffset(math.floor(gapCenter - GRAB / 2), node.rect.pos.Y)
                    splitter.Size = UDim2.fromOffset(GRAB, node.rect.size.Y)
                    if line then
                        line.Size = UDim2.new(0, GUTTER, 1, 0)
                    end
                else
                    local ah: number = math.floor((node.rect.size.Y - GUTTER) * node.ratio)
                    local gapCenter: number = node.rect.pos.Y + ah + GUTTER / 2
                    splitter.Position = UDim2.fromOffset(node.rect.pos.X, math.floor(gapCenter - GRAB / 2))
                    splitter.Size = UDim2.fromOffset(node.rect.size.X, GRAB)
                    if line then
                        line.Size = UDim2.new(1, 0, 0, GUTTER)
                    end
                end
            elseif node.kind == "leaf" and node.rect then
                liveLeaves[nodeId] = true
                local bar = getTabBar(nodeId, container)
                bar.Position = UDim2.fromOffset(node.rect.pos.X, node.rect.pos.Y)
                bar.Size = UDim2.fromOffset(node.rect.size.X, TAB_HEIGHT)

                if node.active == nil or table.find(node.windows, node.active) == nil then
                    node.active = node.windows[1]
                end

                local contentPos: Vector2 = node.rect.pos + Vector2.new(0, TAB_HEIGHT)
                local contentSize: Vector2 = Vector2.new(node.rect.size.X, math.max(node.rect.size.Y - TAB_HEIGHT, 0))

                for index, windowId in node.windows do
                    liveTabs[windowId] = true
                    local button = getTabButton(windowId, bar)
                    button.LayoutOrder = index
                    local widget: Types.Widget? = Iris._windowWidgets[windowId]
                    local isActive: boolean = node.active == windowId
                    button.Text = if widget and widget.arguments.Title then widget.arguments.Title else windowId
                    button.BackgroundColor3 = if isActive then Iris._config.TitleBgActiveColor else Iris._config.TitleBgColor
                    button.BackgroundTransparency = if isActive then Iris._config.TitleBgActiveTransparency else 1

                    if widget then
                        widget.dockId = nodeId
                        -- pin docked windows beneath the dock container so chrome stays grabbable
                        if widget.Instance then
                            widget.Instance.ZIndex = DOCKED_WINDOW_ZINDEX
                            applyDockedChrome(widget.Instance)
                        end
                        setStateIfChanged(widget.state.isOpened, isActive)
                        if isActive then
                            setStateIfChanged(widget.state.isUncollapsed, true)
                            setStateIfChanged(widget.state.position, contentPos)
                            setStateIfChanged(widget.state.size, contentSize)
                        end
                    end
                end
            end
        end

        -- reap UI instances for nodes/windows that no longer exist
        for leafId, bar in dock.tabBars do
            if not liveLeaves[leafId] then
                bar:Destroy()
                dock.tabBars[leafId] = nil
            end
        end
        for windowId, button in dock.tabButtons do
            if not liveTabs[windowId] then
                button:Destroy()
                dock.tabButtons[windowId] = nil
            end
        end
        for splitId, splitter in dock.splitters do
            if not liveSplitters[splitId] then
                splitter:Destroy()
                dock.splitters[splitId] = nil
            end
        end

        -- settled-geometry diagnostic: AbsolutePosition lags a frame after layout, so we dump
        -- for a few frames following any structural change to capture real stacking/hit-areas.
        if dock._dumpFrames and dock._dumpFrames > 0 then
            dock._dumpFrames -= 1
            if dock._dumpFrames == 0 then
                print("[DOCK][Z] container z=", container.ZIndex, "absPos=", container.AbsolutePosition, "absSize=", container.AbsoluteSize)
                for splitId, splitter in dock.splitters do
                    print("[DOCK][Z] splitter", splitId, "z=", splitter.ZIndex, "absPos=", splitter.AbsolutePosition, "absSize=", splitter.AbsoluteSize, "visible=", splitter.Visible)
                end
                for leafId, bar in dock.tabBars do
                    print("[DOCK][Z] tabbar", leafId, "z=", bar.ZIndex, "absPos=", bar.AbsolutePosition, "absSize=", bar.AbsoluteSize)
                end
                for _, node in dock.nodes do
                    if node.kind == "leaf" and node.active then
                        local widget = Iris._windowWidgets[node.active]
                        local inst = widget and widget.Instance :: Frame?
                        if inst then
                            local wb = inst:FindFirstChild("WindowButton") :: GuiObject?
                            local cc = wb and wb:FindFirstChild("Content") and (wb.Content :: any):FindFirstChild("WindowContainer") :: GuiObject?
                            print(
                                "[DOCK][Z] dockedWin", node.active,
                                "windowZ=", inst.ZIndex,
                                "btnZ=", wb and wb.ZIndex, "btnAbsPos=", wb and wb.AbsolutePosition, "btnAbsSize=", wb and wb.AbsoluteSize,
                                "containerZ=", cc and cc.ZIndex, "containerAbsPos=", cc and cc.AbsolutePosition, "containerAbsSize=", cc and cc.AbsoluteSize
                            )
                        end
                    end
                end
            end
        end
    end
end
