/*jshint bitwise:true, curly:true, forin:false, noarg:true, noempty:true, nonew:true, undef:true, strict:false, browser:true, jquery:true */

document.addEventListener('DOMContentLoaded', () => {
	if(window.notes) {
		var $img = $('#main_image');
		var initNotes = function() {
			if(typeof $.fn.imgNotes === 'function') {
				$img.imgNotes({notes: window.notes});

				//Make sure notes are always shown
				$img.off('mouseenter mouseleave');
			}
		};

		// jQuery 3 removed the .load(handler) event shortcut.
		$img.on('load', initNotes);
		if($img.length && $img[0].complete && $img[0].naturalWidth > 0) {
			initNotes();
		}
	}

	$('#cancelnote').click(function(){
		$('#main_image').imgAreaSelect({ hide: true });
		$('#noteform').hide();
	});

	$('#EditCancelNote').click(function() {
		$('#main_image').imgAreaSelect({ hide: true });
		$('#noteEditForm').hide();
	});

	$('#addnote').click(function(){
		$('#noteEditForm').hide();
		var image = $('#main_image');
		var width = Math.min(160, image.width());
		var height = Math.min(120, image.height());
		image.imgAreaSelect({ onSelectChange: showaddnote, x1: 0, y1: 0, x2: width, y2: height });
		showaddnote(image[0], {x1: 0, y1: 0, width: width, height: height});
		return false;
	});

	$(document).on('click', '.note', function() {
		if (!window.notes_edit) return;
		$('#noteform').hide();
		var imgOffset = $('#main_image').offset();

		var x1 = parseInt(this.style.left) - imgOffset.left;
		var y1 = parseInt(this.style.top) - imgOffset.top;
		var width = parseInt(this.style.width);
		var height = parseInt(this.style.height);
		var text = $(this).next('.notep').text();
		var id = $(this).attr('data-note-id');
		if (!id || !/^[1-9][0-9]*$/.test(id)) return;

		$('#main_image').imgAreaSelect({ onSelectChange: showeditnote, x1: x1, y1: y1, x2: x1 + width, y2: y1 + height });
		setEditNoteData(x1, y1, width, height, text, id);
	});
});
		
function showaddnote (img, area) {
	var imgOffset = $(img).offset();
	var form_left  = parseInt(imgOffset.left) + parseInt(area.x1);
	var form_top   = parseInt(imgOffset.top) + parseInt(area.y1) + parseInt(area.height)+5;

	$('#noteform').css({ left: form_left + 'px', top: form_top + 'px'});
	$('#noteform').show();
	$('#noteform').css('z-index', 10000);
	$('#NoteX1').val(area.x1);
	$('#NoteY1').val(area.y1);
	$('#NoteHeight').val(area.height);
	$('#NoteWidth').val(area.width);
}

function showeditnote (img, area) {
	var imgOffset = $(img).offset();
	var form_left  = parseInt(imgOffset.left) + area.x1;
	var form_top   = parseInt(imgOffset.top) + area.y2;

	$('#noteEditForm').css({ left: form_left + 'px', top: form_top + 'px'});
	$('#noteEditForm').show();
	$('#noteEditForm').css('z-index', 10000);
	$('#EditNoteX1').val(area.x1);
	$('#EditNoteY1').val(area.y1);
	$('#EditNoteHeight').val(area.height);
	$('#EditNoteWidth').val(area.width);
}

function setEditNoteData(x1, y1, width, height, text, id) {
	$('#EditNoteX1').val(x1);
	$('#EditNoteY1').val(y1);
	$('#EditNoteHeight').val(height);
	$('#EditNoteWidth').val(width);
	$('#EditNoteNote').val(text);
	$('#EditNoteID').val(id);
	$('#DeleteNoteNoteID').val(id);
}
