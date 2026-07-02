output "image_queue_name" {
  value = google_cloud_tasks_queue.image.name
}

output "video_queue_name" {
  value = google_cloud_tasks_queue.video.name
}

output "merge_queue_name" {
  value = google_cloud_tasks_queue.merge.name
}

output "text_queue_name" {
  value = google_cloud_tasks_queue.text.name
}
