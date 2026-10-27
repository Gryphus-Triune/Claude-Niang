# Where the widget window sits: the host window or desktop work area it
# follows, its DPI, the character and bubble layout inside the fixed design
# canvas, and the limits that keep the character inside that frame.
function Get-WidgetPlacementFrame {
  if($script:followHost){return [ClaudeWidgetNative]::Frame($script:hostHandle)}
  $point=if($null-ne $script:desktopLeft -and $null-ne $script:desktopTop){[Drawing.Point]::new([int]$script:desktopLeft,[int]$script:desktopTop)}else{[Drawing.Point]::new(0,0)}
  return [Windows.Forms.Screen]::FromPoint($point).WorkingArea
}
function Get-WidgetPlacementDpi {
  $handle=if($script:followHost){$script:hostHandle}else{$script:widgetHandle}
  if(!$handle -or $handle-eq [IntPtr]::Zero){return 1.0}
  $dpi=[ClaudeWidgetNative]::GetDpiForWindow($handle)/96.0
  if($dpi-le 0){$dpi=1};return $dpi
}
function Set-WidgetFollowHost([bool]$Follow) {
  if($script:widgetMusic -and $script:widgetMusic.Enabled){Stop-WidgetMusic}
  if(!$Follow -and $null-eq $script:desktopLeft){
    $frame=[ClaudeWidgetNative]::Frame($script:widgetHandle)
    $script:desktopLeft=$frame.Left;$script:desktopTop=$frame.Top
  }
  $script:followHost=$Follow;$script:lastPosition=$null;$script:attachedHost=[IntPtr]::Zero
  if(!$Follow){$script:hostFollower.Detach();Set-WidgetDesktopLayer $script:widgetHandle $script:desktopTopmost}
  else{Set-WidgetDesktopLayer $script:widgetHandle $false}
  Set-Appearance;Save-Settings;Tick-Widget
}
function Set-Facing {
  $factor=if($script:side-eq 'left'){-1.0}else{1.0}
  $script:ui.FacingScale.ScaleX=$factor;$script:ui.TextFacingScale.ScaleX=$factor
  # Refresh now shares SceneText's mirror compensation with the title.
  $script:ui.Refresh.RenderTransform=[Windows.Media.Transform]::Identity
  $script:ui.MenuButton.RenderTransformOrigin=[Windows.Point]::new(0.5,0.5)
  $script:ui.MenuButton.RenderTransform=[Windows.Media.ScaleTransform]::new($factor,1)
}
function Get-WidgetLayoutScale {
  $bubble=if($script:bubbleScale-ge 0.6 -and $script:bubbleScale-le 2.5){[double]$script:bubbleScale}else{[double]$script:scale}
  return [Math]::Max([double]$script:scale,$bubble)
}
function Set-WidgetIndependentLayout {
  if(!$script:ui.Girl){return}
  $layoutScale=Get-WidgetLayoutScale
  $bubbleScale=if($script:bubbleScale-ge 0.6 -and $script:bubbleScale-le 2.5){[double]$script:bubbleScale}else{[double]$script:scale}
  if($script:ui.Girl){
    $character=$script:scale/$layoutScale;$bubble=$bubbleScale/$layoutScale
    $girlLeft=350-208*$character;$girlTop=350-208*$character
    $script:ui.Girl.Width=208*$character;$script:ui.Girl.Height=208*$character
    [Windows.Controls.Canvas]::SetLeft($script:ui.Girl,$girlLeft)
    [Windows.Controls.Canvas]::SetTop($script:ui.Girl,$girlTop)
    $script:ui.Bubble.LayoutTransform=[Windows.Media.ScaleTransform]::new($bubble,$bubble)
    $bubbleLeft=[Math]::Max(0,[Math]::Min(350-350*$bubble,$girlLeft+104*$character-246*$bubble))
    [Windows.Controls.Canvas]::SetLeft($script:ui.Bubble,$bubbleLeft)
    # A large bubble must stay inside the fixed design canvas; otherwise the
    # window clips its bottom edge for small characters with bubble scale 250%.
    $bubbleTop=[Math]::Max(0,[Math]::Min(350-239*$bubble,$girlTop-142*$bubble))
    [Windows.Controls.Canvas]::SetTop($script:ui.Bubble,$bubbleTop)
    $script:ui.Tail.Width=25*$character;$script:ui.Tail.Height=18*$character
    [Windows.Controls.Canvas]::SetLeft($script:ui.Tail,$girlLeft-34*$character)
    [Windows.Controls.Canvas]::SetTop($script:ui.Tail,$girlTop+40*$character)
    $script:ui.TailNear.Width=17*$character;$script:ui.TailNear.Height=12*$character
    [Windows.Controls.Canvas]::SetLeft($script:ui.TailNear,$girlLeft)
    [Windows.Controls.Canvas]::SetTop($script:ui.TailNear,$girlTop+72*$character)
    $script:ui.MenuButton.Width=24*$character;$script:ui.MenuButton.Height=24*$character
    if($script:ui.MenuButton.Content-is [Windows.Controls.Viewbox]){
      $script:ui.MenuButton.Content.Width=14*$character;$script:ui.MenuButton.Content.Height=14*$character
    }
    [Windows.Controls.Canvas]::SetLeft($script:ui.MenuButton,350-30*$character)
    [Windows.Controls.Canvas]::SetTop($script:ui.MenuButton,$girlTop+20*$character)
  }
  if($script:widgetMusic -and $script:widgetMusic.Enabled){$script:widgetMusic.CaptureBaseLayout()}
}
function Set-Appearance {
  $previousDisplayScale=$script:displayScale
  $actual=Get-WidgetLayoutScale
  if(!$script:followHost){
    $frame=Get-WidgetPlacementFrame;$dpi=Get-WidgetPlacementDpi
    if(Test-WidgetPlacementFrame $frame $dpi){$actual=[Math]::Min($actual,[Math]::Min(($frame.Right-$frame.Left)/$dpi/$script:designWidth,($frame.Bottom-$frame.Top)/$dpi/$script:designHeight))}
  }
  if($script:followHost -and $previousDisplayScale-gt 0 -and [Math]::Abs($actual-$previousDisplayScale)-gt 0.001){
    # Offsets that deliberately place the transparent window edge outside the
    # host were measured with the previous window size. Scale them with the
    # display size so a later resize keeps the character flush instead of
    # drifting by the transparent margin.
    $ratio=$actual/$previousDisplayScale
    if($script:offsetBottom-lt 0){$script:offsetBottom=[Math]::Round($script:offsetBottom*$ratio,3)}
    if($script:offsetRight-lt 0){$script:offsetRight=[Math]::Round($script:offsetRight*$ratio,3)}
    if($null-ne $script:offsetLeft -and $script:offsetLeft-lt 0){$script:offsetLeft=[Math]::Round($script:offsetLeft*$ratio,3)}
  }
  $script:displayScale=$actual
  # Transparent space around the original 350px pose contains press/rebound
  # overshoot without shrinking the character or exposing a rectangular cut.
  $null=Set-WidgetPixelSize (Get-WidgetPlacementDpi)
  Set-WidgetIndependentLayout
  # The Viewbox scales the completed pose, including the mirror origin and press motion.
  # Scaling and mirroring this same Canvas made its origin escape the native window.
  $script:ui.Root.LayoutTransform=[Windows.Media.Transform]::Identity
  Set-Facing
  $script:lastPosition=$null
  if($script:hostEventTimer -and !$script:hostEventTimer.IsEnabled){$script:hostEventTimer.Start()}
}
function Test-WidgetPlacementFrame($Frame,[double]$Dpi=1) {
  return $Frame -and $Dpi-gt 0 -and ($Frame.Right-$Frame.Left)-ge 64*$Dpi -and ($Frame.Bottom-$Frame.Top)-ge 64*$Dpi
}
function Test-WidgetDesktopCoordinates {
  return ($null-ne [Windows.PresentationSource]::FromVisual($script:window) -and $null-ne [Windows.PresentationSource]::FromVisual($script:ui.Root.Parent))
}
function Limit-WidgetHorizontalPosition($Frame,[double]$Dpi,[double]$Left) {
  # Mirror-aware character bounds; transparent bubble space may extend outside.
  # Use the resting layout so press/rebound never changes the drag limits.
  $root=$script:ui.Root;$girl=$script:ui.Girl
  $rootOffset=[Windows.Media.VisualTreeHelper]::GetOffset($root)
  $girlOffset=[Windows.Media.VisualTreeHelper]::GetOffset($girl)
  $girlLeft=$girlOffset.X
  if($script:ui.FacingScale.ScaleX-lt 0){$girlLeft=$root.ActualWidth-$girlOffset.X-$girl.ActualWidth}
  $leftInStage=$rootOffset.X+$girlLeft
  $origin=$script:window.PointToScreen([Windows.Point]::new(0,0))
  $leftPoint=$root.Parent.PointToScreen([Windows.Point]::new($leftInStage,0))
  $rightPoint=$root.Parent.PointToScreen([Windows.Point]::new(($leftInStage+$girl.ActualWidth),0))
  $minimum=$Frame.Left-($leftPoint.X-$origin.X)
  $maximum=$Frame.Right-($rightPoint.X-$origin.X)
  if($maximum-lt $minimum){return [int][Math]::Round(($minimum+$maximum)/2)}
  return [int][Math]::Round([Math]::Max($minimum,[Math]::Min($maximum,$Left)))
}
function Limit-WidgetVerticalPosition($Frame,[double]$Dpi,[double]$Top) {
  # Keep the character inside the frame; the transparent space reserved for
  # its bubble may extend above it. Ignore transient press/rebound transforms.
  $root=$script:ui.Root;$girl=$script:ui.Girl
  $rootOffset=[Windows.Media.VisualTreeHelper]::GetOffset($root)
  $girlOffset=[Windows.Media.VisualTreeHelper]::GetOffset($girl)
  $left=$rootOffset.X+$girlOffset.X;$topInStage=$rootOffset.Y+$girlOffset.Y
  $origin=$script:window.PointToScreen([Windows.Point]::new(0,0))
  $topPoint=$root.Parent.PointToScreen([Windows.Point]::new($left,$topInStage))
  $bottomPoint=$root.Parent.PointToScreen([Windows.Point]::new($left,($topInStage+$girl.ActualHeight)))
  $minimum=$Frame.Top-($topPoint.Y-$origin.Y)
  $maximum=$Frame.Bottom-($bottomPoint.Y-$origin.Y)
  return [int][Math]::Round([Math]::Max($minimum,[Math]::Min($maximum,$Top)))
}
function Get-WidgetCharacterPixelBounds([double]$Dpi) {
  # Resting character bounds, excluding transparent bubble/animation padding.
  $root=$script:ui.Root;$girl=$script:ui.Girl
  $source=[Windows.PresentationSource]::FromVisual($script:window)
  if($source -and $source.CompositionTarget -and $root.Parent -and $null-ne [Windows.PresentationSource]::FromVisual($root.Parent)){
    # Use arranged (pixel-rounded) offsets once connected. Canvas coordinates
    # alone can differ by several pixels at large independent bubble scales.
    if(!$root.IsArrangeValid -or !$girl.IsArrangeValid){$script:window.UpdateLayout()}
    $rootOffset=[Windows.Media.VisualTreeHelper]::GetOffset($root)
    $girlOffset=[Windows.Media.VisualTreeHelper]::GetOffset($girl)
    $left=$girlOffset.X
    if($script:ui.FacingScale.ScaleX-lt 0){$left=$root.ActualWidth-$left-$girl.ActualWidth}
    $left+=$rootOffset.X;$top=$rootOffset.Y+$girlOffset.Y
    $transform=$root.Parent.TransformToAncestor($script:window)
    $a=$transform.Transform([Windows.Point]::new($left,$top))
    $b=$transform.Transform([Windows.Point]::new(($left+$girl.ActualWidth),($top+$girl.ActualHeight)))
    $a=$source.CompositionTarget.TransformToDevice.Transform($a)
    $b=$source.CompositionTarget.TransformToDevice.Transform($b)
    return [int[]]@($a.X,$a.Y,$b.X,$b.Y)
  }
  # Before Show there is no presentation target; use the known design layout.
  $left=[Windows.Controls.Canvas]::GetLeft($girl)
  if($script:ui.FacingScale.ScaleX-lt 0){$left=$root.Width-$left-$girl.Width}
  $left+=[Windows.Controls.Canvas]::GetLeft($root)
  $top=[Windows.Controls.Canvas]::GetTop($root)+[Windows.Controls.Canvas]::GetTop($girl)
  $factor=$script:displayScale*$Dpi
  return [int[]]@(($left*$factor),($top*$factor),(($left+$girl.Width)*$factor),(($top+$girl.Height)*$factor))
}
function Get-WidgetVisibleFrame {
  $frame=[ClaudeWidgetNative]::Frame($script:hostHandle)
  $dpi=Get-WidgetPlacementDpi
  if(!(Test-WidgetPlacementFrame $frame $dpi)){return $frame}
  $width=$script:designWidth*$script:displayScale*$dpi;$height=$script:designHeight*$script:displayScale*$dpi
  $x=if($script:anchor-eq 'right'){$frame.Right-$width-$script:offsetRight*$dpi}else{$frame.Left+$script:offsetLeft*$dpi}
  $y=$frame.Bottom-$height-$script:offsetBottom*$dpi
  $bounds=[ClaudeWidgetHostFollower]::VisibleBoundsAt($frame.Left,$frame.Top,$frame.Right,$frame.Bottom,[int]($x+$width/2),[int]($y+$height/2))
  $frame.Left=$bounds[0];$frame.Top=$bounds[1];$frame.Right=$bounds[2];$frame.Bottom=$bounds[3]
  return $frame
}
function Set-WidgetPixelSize([double]$dpi){
  # Only the immutable design canvas participates in physical size calculation.
  $pixels=$script:designWidth*$script:displayScale*$dpi
  $pixelHeight=$script:designHeight*$script:displayScale*$dpi
  $source=[Windows.PresentationSource]::FromVisual($script:window)
  $sx=1.0;$sy=1.0
  if($source -and $source.CompositionTarget){
    $matrix=$source.CompositionTarget.TransformToDevice;$sx=$matrix.M11;$sy=$matrix.M22
  }
  $width=$pixels/$sx;$height=$pixelHeight/$sy;$changed=$false
  if([Math]::Abs($script:window.Width-$width)-gt 0.01){$script:window.Width=$width;$changed=$true}
  if([Math]::Abs($script:window.Height-$height)-gt 0.01){$script:window.Height=$height;$changed=$true}
  if($changed){$script:window.UpdateLayout()}
  return [int][Math]::Round($pixels)
}
