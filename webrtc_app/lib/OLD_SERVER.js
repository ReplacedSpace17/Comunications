// server.js
const express = require('express');
const http = require('http');
const socketIo = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = socketIo(server);

io.on('connection', (socket) => {
  console.log('a user connected:', socket.id);

  socket.on('offer', (data) => {
    console.log('Offer received:', data);
    socket.broadcast.emit('offer', data);
  });

  socket.on('answer', (data) => {
    console.log('Answer received:', data);
    socket.broadcast.emit('answer', data);
  });

  socket.on('candidate', (data) => {
    console.log('Candidate received:', data);
    socket.broadcast.emit('candidate', data);
  });

  socket.on('disconnect', () => {
    console.log('user disconnected:', socket.id);
  });
});

server.listen(3000, () => {
  console.log('Server is listening on port 3000');
});